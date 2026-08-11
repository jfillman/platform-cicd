// platform/broker/internal/githubapp/githubapp.go
//
// Shared GitHub App client (JWT signing + installation-token minting), extracted from
// cmd/token-review-interceptor/github_app.go so cmd/argocd-outcome-relay can use the
// identical, already-correct implementation rather than a second copy - see that
// relay's own main.go for why it needs this directly (not via the broker's
// /github-installation-token HTTP endpoint): that endpoint's authorization check
// (verifyAppOwnsRepo) trusts only the CALLER's own TokenReview-verified app namespace,
// which fits every per-Application caller this platform has had until now but not a
// platform-wide service like the relay that legitimately needs tokens for potentially
// any app's gitops repo. The relay holding this client directly (same credential,
// same narrow per-request repo scoping) is a second platform-level trust boundary of
// the same shape as token-review-interceptor's own, not a widening of what any single
// Application can reach.
//
// Standard library only for the JWT signing (RS256) - see the original file's own
// header for why a JWT library isn't worth pulling in for this.
package githubapp

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"
)

const (
	appIDPath     = "/etc/github-app/github-application-id"
	appKeyPath    = "/etc/github-app/github-private-key"
	githubAPIBase = "https://api.github.com"
)

type Creds struct {
	appID      string
	privateKey *rsa.PrivateKey
}

// LoadCreds reads the App ID/private key from the same fixed paths
// charts/platform-cicd-control-plane/templates/broker/interceptor.yaml (and now
// templates/clusters/argocd-outcome-relay.yaml) mount the hand-created
// github-app-creds Secret at - see that manifest's own header for how that Secret is
// provisioned (a copy of two fields from PaC's own secret, never pasted through chat).
func LoadCreds() (*Creds, error) {
	idBytes, err := os.ReadFile(appIDPath)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", appIDPath, err)
	}
	keyBytes, err := os.ReadFile(appKeyPath)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", appKeyPath, err)
	}
	block, _ := pem.Decode(keyBytes)
	if block == nil {
		return nil, fmt.Errorf("%s does not contain a PEM block", appKeyPath)
	}
	key, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		// GitHub App keys are sometimes issued as PKCS8 rather than PKCS1.
		parsed, err2 := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err2 != nil {
			return nil, fmt.Errorf("parsing private key (tried PKCS1 and PKCS8): %v / %v", err, err2)
		}
		rsaKey, ok := parsed.(*rsa.PrivateKey)
		if !ok {
			return nil, fmt.Errorf("private key is not RSA")
		}
		key = rsaKey
	}
	return &Creds{appID: string(bytes.TrimSpace(idBytes)), privateKey: key}, nil
}

// SignAppJWT builds the short-lived JWT GitHub requires for App-level (not
// installation-level) API calls: RS256 over {"alg":"RS256","typ":"JWT"} and
// {"iat","exp","iss"} claims, base64url-encoded and dot-joined per the JWT spec.
func (c *Creds) SignAppJWT() (string, error) {
	now := time.Now()
	header := base64URLEncode([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, err := json.Marshal(map[string]any{
		// Backdated 60s: GitHub explicitly recommends this to tolerate clock drift
		// between this pod and GitHub's own servers.
		"iat": now.Add(-60 * time.Second).Unix(),
		"exp": now.Add(9 * time.Minute).Unix(),
		"iss": c.appID,
	})
	if err != nil {
		return "", err
	}
	payload := base64URLEncode(claims)
	signingInput := header + "." + payload

	hashed := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, c.privateKey, crypto.SHA256, hashed[:])
	if err != nil {
		return "", fmt.Errorf("signing JWT: %w", err)
	}
	return signingInput + "." + base64URLEncode(sig), nil
}

func base64URLEncode(b []byte) string {
	return base64.RawURLEncoding.EncodeToString(b)
}

// InstallationIDForRepo looks up the App's installation ID for a specific repo,
// authenticated with the App-level JWT (not an installation token, which doesn't exist
// yet at this point) - avoids needing to statically configure/store installation IDs
// anywhere, since a repo can only resolve to an installation ID at all once the App is
// actually installed on it (a manual step - see docs/release.md).
func InstallationIDForRepo(appJWT, owner, repo string) (int64, error) {
	req, err := http.NewRequest(http.MethodGet, fmt.Sprintf("%s/repos/%s/%s/installation", githubAPIBase, owner, repo), nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+appJWT)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("calling GitHub installation lookup: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("GitHub installation lookup for %s/%s: status %d: %s", owner, repo, resp.StatusCode, string(body))
	}
	var parsed struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return 0, fmt.Errorf("parsing installation lookup response: %w", err)
	}
	return parsed.ID, nil
}

// MintInstallationToken exchanges the App-level JWT for a short-lived installation
// token scoped to exactly one repository - GitHub's `repositories` field on this
// endpoint is what makes the returned token unable to touch any other repo the App
// might be installed on, which is the whole point: whoever calls this holds the App's
// private key, but nothing it hands back can reach further than the one repo asked for.
func MintInstallationToken(appJWT string, installationID int64, repo string) (token string, expiresAt string, err error) {
	reqBody, _ := json.Marshal(map[string]any{"repositories": []string{repo}})
	req, err := http.NewRequest(http.MethodPost,
		fmt.Sprintf("%s/app/installations/%s/access_tokens", githubAPIBase, strconv.FormatInt(installationID, 10)),
		bytes.NewReader(reqBody))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Authorization", "Bearer "+appJWT)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("calling GitHub access-token exchange: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusCreated {
		return "", "", fmt.Errorf("GitHub access-token exchange for installation %d, repo %s: status %d: %s", installationID, repo, resp.StatusCode, string(body))
	}
	var parsed struct {
		Token     string `json:"token"`
		ExpiresAt string `json:"expires_at"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return "", "", fmt.Errorf("parsing access-token response: %w", err)
	}
	return parsed.Token, parsed.ExpiresAt, nil
}
