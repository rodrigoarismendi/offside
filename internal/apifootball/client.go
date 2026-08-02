package apifootball

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"offside/internal/config"
)

type Client struct {
	http   *http.Client
	apiKey string
	host   string
}

func New(cfg config.Config) *Client {
	return &Client{
		http:   &http.Client{Timeout: 30 * time.Second},
		apiKey: cfg.APIKey,
		host:   cfg.APIHost,
	}
}

// envelope describes ONLY the wrapper. Each response element stays raw bytes.
type envelope struct {
	Errors   json.RawMessage   `json:"errors"`
	Results  int               `json:"results"`
	Response []json.RawMessage `json:"response"`
}

// Get calls an endpoint and returns response[] as raw JSON blobs.
func (c *Client) Get(ctx context.Context, path string, params url.Values) ([]json.RawMessage, error) {
	u := url.URL{Scheme: "https", Host: c.host, Path: path, RawQuery: params.Encode()}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("building request: %w", err)
	}
	req.Header.Set("x-apisports-key", c.apiKey)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("calling %s: %w", path, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading body: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s returned HTTP %d: %s", path, resp.StatusCode, body)
	}

	var env envelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decoding envelope: %w", err)
	}

	// errors is `[]` on success; an object/array with content signals a problem.
	if s := string(env.Errors); len(env.Errors) > 0 && s != "[]" && s != "{}" {
		return nil, fmt.Errorf("%s API errors: %s", path, s)
	}

	return env.Response, nil
}