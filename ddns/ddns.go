package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	gandiAPI       = "https://api.gandi.net/v5/livedns/domains"
	checkIPv4      = "https://ipv4.icanhazip.com"
	checkIPv6      = "https://ipv6.icanhazip.com"
	domain         = "mfilipe.eu"
	refreshSeconds = 300
)

var records = []string{"tv", "img", "home", "graf", "notes", "www", "blog"}

func getIP(url string) (string, error) {
	resp, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	ip := strings.TrimSpace(string(body))
	if net.ParseIP(ip) == nil {
		return "", fmt.Errorf("invalid IP address: %q, raw response: %q", ip, string(body))
	}
	return ip, nil
}

func updateRecord(token, subdomain, recordType, ip string) error {
	url := fmt.Sprintf("%s/%s/records/%s/%s", gandiAPI, domain, subdomain, recordType)
	payload := map[string]any{
		"rrset_values": []string{ip},
		"rrset_ttl":    refreshSeconds,
	}
	data, _ := json.Marshal(payload)

	req, _ := http.NewRequest("PUT", url, bytes.NewBuffer(data))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 && resp.StatusCode != 201 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, body)
	}
	return nil
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	token := os.Getenv("GANDI_API_TOKEN")
	if token == "" {
		slog.Error("GANDI_API_TOKEN not set")
		os.Exit(1)
	}

	for {
		ipv4, err := getIP(checkIPv4)
		if err != nil {
			slog.Error("failed to get IPv4", "error", err)
		} else {
			for _, rec := range records {
				if err := updateRecord(token, rec, "A", ipv4); err != nil {
					slog.Error("failed to update A record", "subdomain", rec, "error", err)
				} else {
					slog.Info("updated A record", "subdomain", rec, "domain", domain, "ip", ipv4)
				}
			}
		}

		ipv6, err := getIP(checkIPv6)
		if err != nil {
			slog.Error("failed to get IPv6", "error", err)
		} else {
			for _, rec := range records {
				if err := updateRecord(token, rec, "AAAA", ipv6); err != nil {
					slog.Error("failed to update AAAA record", "subdomain", rec, "error", err)
				} else {
					slog.Info("updated AAAA record", "subdomain", rec, "domain", domain, "ip", ipv6)
				}
			}
		}

		time.Sleep(refreshSeconds * time.Second)
	}
}
