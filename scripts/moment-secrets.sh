#!/bin/zsh
# Puts the R2 keys and the cleanup secret where the 순간 (Moments) server needs them.
# Paste the two values from Cloudflare's R2 API token screen when asked; they are read
# without echoing, written to a private temp file for the Supabase CLI, and deleted after.
# The cleanup secret is generated here and stored both as an Edge Function secret
# (CRON_SECRET) and in Vault (moment_cron_secret) for the hourly pg_cron job.
set -euo pipefail
cd "${0:A:h}/.."

REF=rqnwgvfirkfxfawnawzf
ACCOUNT_ID=94e021646694f799f35b143253ff8d11
SUPABASE=(npx -y supabase@3.1.0)

echo "Cloudflare R2 API 토큰 화면의 값을 복사해서 붙여 넣고 Enter를 누르세요."
echo "(붙여 넣어도 화면에는 아무것도 안 보이는 게 정상이에요.)"
read -rs "AK?Access Key ID: "; echo
read -rs "SK?Secret Access Key: "; echo
AK="${AK//[[:space:]]/}"
SK="${SK//[[:space:]]/}"
if [[ ${#AK} -lt 20 || ${#SK} -lt 40 ]]; then
  echo "값이 너무 짧아요. Access Key ID와 Secret Access Key를 다시 확인해 주세요."
  exit 1
fi

CRON=$(openssl rand -hex 32)
ENV_FILE=$(mktemp)
chmod 600 "$ENV_FILE"
trap 'rm -f "$ENV_FILE"' EXIT
cat > "$ENV_FILE" <<EOF
R2_ACCOUNT_ID=$ACCOUNT_ID
R2_ACCESS_KEY_ID=$AK
R2_SECRET_ACCESS_KEY=$SK
R2_BUCKET=moments
CRON_SECRET=$CRON
EOF

echo "1/3 서버 함수 비밀값 저장 중…"
"${SUPABASE[@]}" secrets set --remote=$REF --yes --env-file "$ENV_FILE" < /dev/null > /dev/null
rm -f "$ENV_FILE"

echo "2/3 정리 작업용 비밀값을 Vault에 저장 중…"
"${SUPABASE[@]}" db query --remote=$REF --yes "do \$\$ begin
  if exists (select 1 from vault.secrets where name = 'moment_cron_secret') then
    perform vault.update_secret((select id from vault.secrets where name = 'moment_cron_secret'), '$CRON');
  else
    perform vault.create_secret('$CRON', 'moment_cron_secret');
  end if;
end \$\$;" < /dev/null > /dev/null

echo "3/3 확인 중…"
for i in 1 2 3 4 5 6; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "https://$REF.supabase.co/functions/v1/moment-cleanup" \
    -H "Content-Type: application/json" -H "x-cron-secret: $CRON" -d '{}')
  if [[ $CODE == 200 ]]; then
    echo "완료! 비밀값이 모두 들어갔어요. 이제 Claude에게 '등록했어'라고 알려 주세요."
    exit 0
  fi
  sleep 5
done
echo "저장은 했는데 확인 호출이 실패했어요 (HTTP $CODE). 이 메시지를 Claude에게 보내 주세요."
exit 1
