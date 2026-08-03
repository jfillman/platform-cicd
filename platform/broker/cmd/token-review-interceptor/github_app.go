// platform/broker/cmd/token-review-interceptor/github_app.go
//
// Mints short-lived, single-repo-scoped GitHub App installation tokens on behalf of
// tenant pipelines - see docs/release.md and the plan's "Release Stage" section for why
// this lives here rather than as a copy of the App's private key in every tenant
// namespace: Kubernetes Secrets are namespace-scoped, so a tenant Task running in
// platform-cicd-demo can't mount a Secret from pipelines-as-code's namespace, and
// copying the key into every tenant namespace would mean a single compromised tenant
// Task could mint tokens for every OTHER tenant's repos too. This service already holds
// the same TokenReview trust boundary as the CDEvents broker path in main.go, so it's a
// scope extension of an existing trusted component rather than a new one.
//
// Standard library only for the JWT signing (RS256) - GitHub's own documented App-auth
// recipe is a small enough amount of code that pulling in a JWT library isn't worth it,
// and it keeps this service's dependency footprint exactly what it was before (only
// k8s.io/client-go, no new third-party package).
package main

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
	githubAppIDPath      = "/etc/github-app/github-application-id"
	githubAppKeyPath     = "/etc/github-app/github-private-key"
	githubAPIBase        = "https://api.github.com"
	installationTokenTTL = 9 * time.Minute // GitHub's own App-JWT max lifetime is 10m; leave a margin.
)

type githubAppCreds struct {
	appID      string
	privateKey *rsa.PrivateKey
}

func loadGitHubAppCreds() (*githubAppCreds, error) {
	idBytes, err := os.ReadFile(githubAppIDPath)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", githubAppIDPath, err)
	}
	keyBytes, err := os.ReadFile(githubAppKeyPath)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", githubAppKeyPath, err)
	}
	block, _ := pem.Decode(keyBytes)
	if block == nil {
		return nil, fmt.Errorf("%s does not contain a PEM block", githubAppKeyPath)
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
	return &githubAppCreds{appID: string(bytes.TrimSpace(idBytes)), privateKey: key}, nil
}

// signAppJWT builds the short-lived JWT GitHub requires for App-level (not
// installation-level) API calls: RS256 over {"alg":"RS256","typ":"JWT"} and
// {"iat","exp","iss"} claims, base64url-encoded and dot-joined per the JWT spec.
func (c *githubAppCreds) signAppJWT() (string, error) {
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

// installationIDForRepo looks up the App's installation ID for a specific repo,
// authenticated with the App-level JWT (not an installation token, which doesn't exist
// yet at this point) - avoids needing to statically configure/store installation IDs
// anywhere, since a repo can only resolve to an installation ID at all once the App is
// actually installed on it (a manual step - see docs/release.md).
func installationIDForRepo(appJWT, owner, repo string) (int64, error) {
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

// mintInstallationToken exchanges the App-level JWT for a short-lived installation
// token scoped to exactly one repository - GitHub's `repositories` field on this
// endpoint is what makes the returned token unable to touch any other repo the App
// might be installed on, which is the whole point: this service holds the App's
// private key, but nothing it hands back to a caller can reach further than the one
// repo that caller asked for and was authorized for (see the caller-side check in
// main.go's handleGitHubInstallationToken).
func mintInstallationToken(appJWT string, installationID int64, repo string) (token string, expiresAt string, err error) {
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
