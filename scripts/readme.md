### revision 일괄변경 - argocd에서 싱크안맞다면 이 부분부터 점검 
```
bash scripts/fix-argocd-revisions.sh hpa2 --apply
```

### 하드코딩된 ip 변수로 적용 
- ips.env 수정 후
```
bash scripts/ipctl.sh scan   #  # 현재 값 확인
bash scripts/ipctl.sh apply
```
