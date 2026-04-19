---
created: 2026-04-19T15:53:38.218Z
title: Add Grafana production DNS record
area: general
files:
  - infrastructure/terraform/envs/production/variables.tf:92
  - infrastructure/terraform/envs/production/main.tf
---

## Problem

Grafana está acessível apenas por caminho interno/túnel IAP e ainda não tem hostname público dedicado no domínio NexaDuo. Isso atrapalha acesso operacional e padronização dos endpoints produtivos.

## Solution

Adicionar o subdomínio `grafana.nexaduo.com` ao provisionamento de DNS de produção no Terraform (Cloudflare), alinhando variável, registro DNS e roteamento correspondente para o serviço de observabilidade.
