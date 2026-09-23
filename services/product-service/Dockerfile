FROM docker.io/library/golang:1.22 AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
# 주의: -ldflags "-s -w" 를 쓰지 않는다. 심볼이 있어야 eBPF 에이전트가 언어를 Go 로 판별한다.
RUN CGO_ENABLED=0 go build -o /out/product-service .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/product-service /product-service
EXPOSE 8080
ENTRYPOINT ["/product-service"]
