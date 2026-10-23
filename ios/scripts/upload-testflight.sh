#!/bin/bash
# Compatibility entry point: official store distribution is removed from MyCMUX.
message='旧官方发布已从MyCMUX移除；本仓当前仅支持已定义个人构建/安装与compile-only，不支持商店发布。'
if [[ $# -eq 1 && "$1" == "--help" ]]; then
  printf '%s\n' "$message"
  exit 0
fi
printf '%s\n' "$message" >&2
exit 64
