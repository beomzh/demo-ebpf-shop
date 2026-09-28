// 상품 서비스 (Go) — 게이트웨이가 호출하고, 상품마다 재고 서비스를 호출해 재고 수량을 붙여 돌려준다.
//
//	GET /products/{id}   상품 정보 + 재고 (재고 → Redis)
//	GET /products        상품 목록 (재고 없이)
//
// 언어 자동 판별을 위해 Go 1.17+ 로, 심볼을 제거하지 않고(-ldflags "-s -w" 금지) 빌드한다.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"time"
)

type Product struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Price int    `json:"price"`
	Stock *int   `json:"stock,omitempty"`
}

var products = func() map[int]Product {
	m := make(map[int]Product, 20)
	for i := 1; i <= 20; i++ {
		m[i] = Product{ID: i, Name: fmt.Sprintf("product-%02d", i), Price: 1000 * (i%9 + 1)}
	}
	return m
}()

var (
	inventoryURL = envOr("INVENTORY_URL", "http://inventory-service:8080")
	httpClient   = &http.Client{Timeout: 2 * time.Second}
)

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// 실제 조회처럼 보이도록 5~30ms 지연을 준다.
func jitter() { time.Sleep(time.Duration(5+rand.IntN(25)) * time.Millisecond) }

// 재고 서비스 호출. 실패하면 재고 없이 상품만 돌려준다 (재고는 부가 정보).
func fetchStock(id int, reqID string) (*int, error) {
	req, err := http.NewRequest(http.MethodGet, fmt.Sprintf("%s/inventory/%d", inventoryURL, id), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Request-Id", reqID)
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("inventory-service status %d", resp.StatusCode)
	}
	var body struct {
		Stock int `json:"stock"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	return &body.Stock, nil
}

func main() {
	port := envOr("PORT", "8080")

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "UP"})
	})
	mux.HandleFunc("GET /products", func(w http.ResponseWriter, r *http.Request) {
		jitter()
		list := make([]Product, 0, len(products))
		for i := 1; i <= len(products); i++ {
			list = append(list, products[i])
		}
		writeJSON(w, http.StatusOK, list)
	})
	mux.HandleFunc("GET /products/{id}", func(w http.ResponseWriter, r *http.Request) {
		reqID := r.Header.Get("X-Request-Id")
		jitter()
		id, err := strconv.Atoi(r.PathValue("id"))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid id"})
			return
		}
		p, ok := products[id]
		if !ok {
			log.Printf("product not found req=%s id=%d", reqID, id)
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		if stock, err := fetchStock(id, reqID); err != nil {
			log.Printf("stock lookup failed req=%s id=%d err=%v", reqID, id, err)
		} else {
			p.Stock = stock
		}
		writeJSON(w, http.StatusOK, p)
	})

	log.Printf("product-service listening on :%s inventory=%s", port, inventoryURL)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
