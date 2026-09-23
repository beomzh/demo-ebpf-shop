// 상품 서비스 (Go).
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
}

var products = func() map[int]Product {
	m := make(map[int]Product, 20)
	for i := 1; i <= 20; i++ {
		m[i] = Product{ID: i, Name: fmt.Sprintf("product-%02d", i), Price: 1000 * (i%9 + 1)}
	}
	return m
}()

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// 실제 조회처럼 보이도록 5~30ms 지연을 준다.
func jitter() { time.Sleep(time.Duration(5+rand.IntN(25)) * time.Millisecond) }

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

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
		jitter()
		id, err := strconv.Atoi(r.PathValue("id"))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid id"})
			return
		}
		p, ok := products[id]
		if !ok {
			log.Printf("product not found id=%d", id)
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		writeJSON(w, http.StatusOK, p)
	})

	log.Printf("product-service listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
