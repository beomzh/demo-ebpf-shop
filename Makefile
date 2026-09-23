# 로컬 스모크 테스트 엔진: podman 이 있으면 podman compose, 없으면 docker compose
# (make local-up ENGINE=docker 처럼 지정 가능)
ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
COMPOSE   := $(ENGINE) compose
LOCAL_ENV := $(if $(filter podman,$(ENGINE)),LOCAL_UID=10001,)

.PHONY: help certs build push check security deploy baseline incident fix reset status firewall traffic cleanup local-up local-fail local-heal local-down

help:            ## 명령 목록
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

certs:           ## 택배사 사설 CA·서버 인증서 생성 (courier-ext/certs)
	./courier-ext/gen-certs.sh

build:           ## 다섯 서비스 이미지 빌드
	./scripts/build-images.sh

push:            ## 이미지 빌드 + 레지스트리 push
	./scripts/build-images.sh --push

check:           ## 클러스터 사전 점검 (커널, CNI, 택배사 도달)
	./scripts/check-prereq.sh

security:        ## 배포 후 보안 점검 (SCC, securityContext, 네트워크 정책)
	./scripts/security-check.sh

deploy:          ## 쿠버네티스에 전체 배포 (정상 상태로 시작)
	./scripts/deploy.sh

baseline:        ## 정상 상태: DNS → 예전 IP
	./scripts/scenario.sh baseline

incident:        ## 사건 발생: 택배사가 IP 를 새 IP 로 변경
	./scripts/scenario.sh incident

fix:             ## 해결: 방화벽에 새 IP 허용
	./scripts/scenario.sh fix

reset:           ## 다음 촬영 준비 (baseline 과 같음)
	./scripts/scenario.sh reset

status:          ## 현재 상태 요약
	./scripts/scenario.sh status

firewall:        ## 방화벽 규칙 목록
	./scripts/scenario.sh firewall

traffic:         ## 부하 발생기 로그 보기
	./scripts/scenario.sh traffic

cleanup:         ## 데모 네임스페이스 삭제
	./scripts/cleanup.sh

local-up:        ## 로컬 스모크 테스트 기동 (podman/docker compose)
	./courier-ext/gen-certs.sh
	cd local && $(LOCAL_ENV) $(COMPOSE) up -d --build

local-fail:      ## 로컬: 택배사 연결 실패 재현
	cd local && $(LOCAL_ENV) COURIER_IP=10.255.255.1 $(COMPOSE) up -d delivery-service

local-heal:      ## 로컬: 정상 복구
	cd local && $(LOCAL_ENV) $(COMPOSE) up -d delivery-service

local-down:      ## 로컬 스모크 테스트 정리
	cd local && $(LOCAL_ENV) $(COMPOSE) down -v
