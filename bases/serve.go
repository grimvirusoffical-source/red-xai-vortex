package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

type serveOptions struct {
	Listen    string
	Cert      string
	Key       string
	ReadyFile string
	ParentPID int
}

type readyState struct {
	Endpoint string `json:"endpoint"`
	BaseID   string `json:"baseID"`
	PID      int    `json:"pid"`
}

func writeReady(path string, state readyState) error {
	b, err := json.Marshal(state)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".base-ready-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(append(b, '\n'))
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func serveWithSignals(h *Host, options serveOptions) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if options.ParentPID > 0 {
		go func() {
			ticker := time.NewTicker(time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					if os.Getppid() != options.ParentPID {
						stop()
						return
					}
				}
			}
		}()
	}
	return serve(ctx, h, options)
}

func serve(ctx context.Context, h *Host, options serveOptions) error {
	catalog, err := h.load()
	if err != nil {
		return err
	}
	host, _, err := net.SplitHostPort(options.Listen)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if (options.Cert == "") != (options.Key == "") {
		return errors.New("TLS requires both -tls-cert and -tls-key")
	}
	if (ip == nil || !ip.IsLoopback()) && (options.Cert == "" || options.Key == "") {
		return errors.New("non-loopback listeners require -tls-cert and -tls-key; prefer a loopback listener behind an authenticated HTTPS tunnel")
	}
	scheme := "http"
	var certificate tls.Certificate
	if options.Cert != "" {
		certificate, err = tls.LoadX509KeyPair(options.Cert, options.Key)
		if err != nil {
			return err
		}
		scheme = "https"
	}
	listener, err := net.Listen("tcp", options.Listen)
	if err != nil {
		return err
	}
	defer listener.Close()
	if scheme == "https" {
		listener = tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12})
	}
	state := readyState{Endpoint: scheme + "://" + listener.Addr().String(), BaseID: catalog.ID, PID: os.Getpid()}
	if options.ReadyFile != "" {
		if err := writeReady(options.ReadyFile, state); err != nil {
			return err
		}
		defer func() {
			// Avoid removing a readiness record replaced by another process.
			var current readyState
			if b, err := os.ReadFile(options.ReadyFile); err == nil && json.Unmarshal(b, &current) == nil && current == state {
				os.Remove(options.ReadyFile)
			}
		}()
	}
	server := &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	done := make(chan struct{})
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		select {
		case <-ctx.Done():
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := server.Shutdown(shutdownCtx); err != nil {
				server.Close()
			}
		case <-done:
		}
	}()
	log.Println("XAI Base host ready (authenticated, read-only)")
	err = server.Serve(listener)
	close(done)
	<-shutdownDone
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
