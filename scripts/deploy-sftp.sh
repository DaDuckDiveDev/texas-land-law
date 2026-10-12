#!/usr/bin/env bash
#
# Upload the contents of ./public to a SiteGround site over SFTP.
#
# Runs in GitHub Actions (.github/workflows/deploy.yml) and from a laptop:
#
#   SITE_DOMAIN=johnw860.sg-host.com SFTP_USER=your-sftp-user \
#   SFTP_KEY_FILE=~/.ssh/siteground bash scripts/deploy-sftp.sh
#
# Settings (environment variables)
#   SITE_DOMAIN          the site's domain on SiteGround              required
#   SFTP_USER            the SFTP username SiteGround shows for the key  required
#   SFTP_KEY             the private key as text, or
#   SFTP_KEY_FILE        the path to a private key file               one is required
#   SFTP_KEY_PASSPHRASE  the key's password, if it has one
#   SFTP_HOST            default: sftp.siteground.net
#   SFTP_PORT            default: 18765
#   REMOTE_DIR           the site's public_html, if it is not found automatically
#   SFTP_HOST_FINGERPRINT  the server's host key fingerprint (SHA256:...). When set,
#                        the upload stops if the server presents any other key.
#   SFTP_KNOWN_HOSTS     known_hosts line(s), another way to pin the server's host key
#   SOURCE_DIR           default: public
#   DRY_RUN=1            show what would be uploaded and upload nothing
#
# The upload only adds and replaces files. It never deletes anything on the server,
# and it never prints the names of other sites on the same SFTP login.

set -euo pipefail

SFTP_HOST="${SFTP_HOST:-sftp.siteground.net}"
SFTP_PORT="${SFTP_PORT:-18765}"
SOURCE_DIR="${SOURCE_DIR:-public}"
SOURCE_DIR="${SOURCE_DIR%/}"
REMOTE_DIR="${REMOTE_DIR:-}"
REMOTE_DIR="${REMOTE_DIR%/}"
PASSPHRASE="${SFTP_KEY_PASSPHRASE:-}"
IN_ACTIONS="${GITHUB_ACTIONS:-}"

say() { printf '%s\n' "$*"; }

# fail "headline" ["detail line" ...]
fail() {
  if [ -n "$IN_ACTIONS" ]; then
    printf '::error title=Not deployed::%s\n' "$1"
  else
    printf 'Not deployed: %s\n' "$1" >&2
  fi
  shift
  local line
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
  exit 1
}

# ---------- 1. Settings ----------

missing=()
[ -n "${SITE_DOMAIN:-}" ] || missing+=("SITE_DOMAIN")
[ -n "${SFTP_USER:-}" ] || missing+=("SFTP_USER")
[ -n "${SFTP_KEY:-}${SFTP_KEY_FILE:-}" ] || missing+=("SFTP_KEY")
if [ "${#missing[@]}" -gt 0 ]; then
  where="Set them in the environment and run again."
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    where="Add them at https://github.com/${GITHUB_REPOSITORY}/settings/secrets/actions and re-run this job."
  fi
  fail "missing ${missing[*]}." "$where"
fi

case "$SITE_DOMAIN" in
  *[!A-Za-z0-9.-]* | .* | *..*) fail "SITE_DOMAIN \"$SITE_DOMAIN\" is not a domain name." ;;
esac
case "$SFTP_PORT" in
  '' | *[!0-9]*) fail "SFTP_PORT \"$SFTP_PORT\" is not a port number." ;;
esac
# shellcheck disable=SC1003  # the patterns below match a literal backslash
case "$REMOTE_DIR" in
  *'"'* | *'\'* | *$'\n'*) fail "REMOTE_DIR contains a quote, backslash or line break." ;;
esac

[ -d "$SOURCE_DIR" ] || fail "there is no \"$SOURCE_DIR\" folder to upload."

for tool in sftp ssh-keygen ssh-keyscan; do
  command -v "$tool" >/dev/null 2>&1 || fail "\"$tool\" is not installed (it comes with OpenSSH)."
done

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

# ---------- 2. The key ----------

key="$work/key"
if [ -n "${SFTP_KEY:-}" ]; then
  printf '%s\n' "$SFTP_KEY" > "$key"
else
  [ -f "$SFTP_KEY_FILE" ] || fail "SFTP_KEY_FILE \"$SFTP_KEY_FILE\" does not exist."
  cat "$SFTP_KEY_FILE" > "$key"
fi
chmod 600 "$key"

# Keys pasted into a secrets box often arrive with Windows line endings, or flattened
# onto one line with literal "\n" in place of the line breaks. Put them right.
tr -d '\r' < "$key" > "$key.tmp"
if [ "$(grep -c '' "$key.tmp")" -le 1 ] && grep -q '\\n' "$key.tmp"; then
  sed 's/\\n/\n/g' "$key.tmp" > "$key"
else
  cat "$key.tmp" > "$key"
fi
rm -f "$key.tmp"

if ! key_error="$(ssh-keygen -y -P "$PASSPHRASE" -f "$key" 2>&1 >/dev/null)"; then
  case "$key_error" in
    *"incorrect passphrase"*)
      if [ -n "$PASSPHRASE" ]; then
        fail "SFTP_KEY_PASSPHRASE does not unlock SFTP_KEY." \
          "Use the password you typed when you created the key in SiteGround."
      fi
      fail "SFTP_KEY is protected by a password. Add that password as SFTP_KEY_PASSPHRASE."
      ;;
    *)
      fail "SFTP_KEY is not a usable private key." \
        "Paste the whole key, from the -----BEGIN line to the -----END line." \
        "ssh-keygen said: ${key_error##*: }"
      ;;
  esac
fi

# Work with an unlocked copy. It lives in a private temp folder and is removed on exit.
if [ -n "$PASSPHRASE" ]; then
  ssh-keygen -p -q -P "$PASSPHRASE" -N "" -f "$key" >/dev/null 2>&1 \
    || fail "could not unlock SFTP_KEY with SFTP_KEY_PASSPHRASE."
fi

# ---------- 3. The server's host key ----------

known_hosts="$work/known_hosts"
if [ -n "${SFTP_KNOWN_HOSTS:-}" ]; then
  printf '%s\n' "$SFTP_KNOWN_HOSTS" > "$known_hosts"
else
  for _ in 1 2 3; do
    ssh-keyscan -T 15 -p "$SFTP_PORT" "$SFTP_HOST" > "$known_hosts" 2>/dev/null || true
    [ -s "$known_hosts" ] && break
    sleep 3
  done
  [ -s "$known_hosts" ] || fail "could not reach $SFTP_HOST on port $SFTP_PORT." \
    "Check SFTP_HOST and SFTP_PORT."
fi

# With a fingerprint to check against, trust only the key that matches it.
if [ -n "${SFTP_HOST_FINGERPRINT:-}" ]; then
  : > "$work/known_hosts.pinned"
  seen=""
  while IFS= read -r host_line; do
    case "$host_line" in '' | '#'*) continue ;; esac
    printf '%s\n' "$host_line" > "$work/one_host_key"
    fingerprint="$(ssh-keygen -lf "$work/one_host_key" 2>/dev/null | awk '{print $2}')" || fingerprint=""
    [ -n "$fingerprint" ] || continue
    seen="$seen $fingerprint"
    if [ "$fingerprint" = "$SFTP_HOST_FINGERPRINT" ]; then
      printf '%s\n' "$host_line" >> "$work/known_hosts.pinned"
    fi
  done < "$known_hosts"
  [ -s "$work/known_hosts.pinned" ] || fail "$SFTP_HOST is not presenting the expected host key." \
    "Expected: $SFTP_HOST_FINGERPRINT" \
    "Got:     ${seen:- none}" \
    "If SiteGround changed its key, confirm the new fingerprint with them, then update SFTP_HOST_FINGERPRINT."
  cat "$work/known_hosts.pinned" > "$known_hosts"
fi

# sftp_run: run the SFTP commands given on stdin.
sftp_run() {
  sftp -b - -P "$SFTP_PORT" -i "$key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o PreferredAuthentications=publickey \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$known_hosts" \
    -o GlobalKnownHostsFile=/dev/null \
    -o ConnectTimeout=20 \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 \
    -o LogLevel=ERROR \
    "$SFTP_USER@$SFTP_HOST"
}

remote_dir_exists() { printf 'cd "%s"\n' "$1" | sftp_run >/dev/null 2>&1; }

# ---------- 4. Sign in ----------

if ! printf 'pwd\n' | sftp_run >/dev/null 2> "$work/login_error"; then
  login_error="$(tr -d '\r' < "$work/login_error" | tail -n 3)"
  case "$login_error" in
    *"Permission denied"*)
      fail "SiteGround refused the key for this username." \
        "Check that SFTP_USER is exactly the username SiteGround shows for the key," \
        "that SFTP_KEY is that key's private half, and that the key has no IP limit" \
        "(GitHub's servers connect from changing addresses)."
      ;;
    *"Host key verification failed"*)
      if [ -n "${SFTP_KNOWN_HOSTS:-}" ]; then
        fail "the server's host key does not match SFTP_KNOWN_HOSTS." \
          "If SiteGround changed its key, update or remove the SFTP_KNOWN_HOSTS variable."
      fi
      fail "the server presented a different host key than the one just checked." \
        "Run the job again. If it keeps happening, stop and check with SiteGround."
      ;;
    *"timed out"* | *"refused"* | *"Could not resolve"* | *"No route"*)
      fail "could not connect to $SFTP_HOST on port $SFTP_PORT." "$login_error"
      ;;
    *)
      fail "the SFTP sign-in failed." "$login_error"
      ;;
  esac
fi

# ---------- 5. Find the site's public_html ----------

if [ -n "$REMOTE_DIR" ]; then
  candidates=("$REMOTE_DIR")
else
  candidates=(
    "/$SITE_DOMAIN/$SITE_DOMAIN/public_html"  # SiteGround Multisite SFTP key
    "$SITE_DOMAIN/$SITE_DOMAIN/public_html"
    "www/$SITE_DOMAIN/public_html"            # single-site SSH key
    "$SITE_DOMAIN/public_html"
  )
fi

remote=""
for candidate in "${candidates[@]}"; do
  if remote_dir_exists "$candidate"; then
    remote="$candidate"
    break
  fi
done

if [ -z "$remote" ]; then
  if [ -n "$REMOTE_DIR" ]; then
    fail "the folder \"$REMOTE_DIR\" (REMOTE_DIR) does not exist on the server."
  fi
  # Say what is inside this site's own folder, if there is one. Never list the top
  # level: on a multisite login it holds the names of every other site.
  inside=""
  for site_folder in "/$SITE_DOMAIN" "$SITE_DOMAIN" "www"; do
    if remote_dir_exists "$site_folder"; then
      inside="$(printf 'ls -1 "%s"\n' "$site_folder" | sftp_run 2>/dev/null | grep -v '^sftp>' | tr -d '\r' | sed "s#^$site_folder/##" | tr '\n' ' ' || true)"
      fail "found the folder \"$site_folder\" but no public_html for $SITE_DOMAIN inside it." \
        "It contains: ${inside:-nothing}" \
        "Set the repository variable SFTP_REMOTE_DIR to the right public_html path."
    fi
  done
  fail "this SFTP login has no folder for $SITE_DOMAIN." \
    "In SiteGround open your profile menu, then Multisite SFTP Access, then the key's" \
    "menu, then Manage Websites, and tick the site. Then re-run this job." \
    "If the folder has another name, set the repository variable SFTP_REMOTE_DIR."
fi

# ---------- 6. Upload ----------

batch="$work/batch"
: > "$batch"
file_count=0

while IFS= read -r -d '' dir; do
  rel="${dir#"$SOURCE_DIR"/}"
  # shellcheck disable=SC1003
  case "$rel" in
    *'"'* | *'\'* | *$'\n'* | *'*'* | *'?'* | *'['*)
      fail "cannot upload the folder \"$rel\": its name has a character SFTP treats specially." ;;
  esac
  printf -- '-mkdir "%s/%s"\n' "$remote" "$rel" >> "$batch"
done < <(find "$SOURCE_DIR" -mindepth 1 -type d -print0 | sort -z)

while IFS= read -r -d '' file; do
  rel="${file#"$SOURCE_DIR"/}"
  case "${rel##*/}" in .DS_Store | Thumbs.db) continue ;; esac
  # shellcheck disable=SC1003
  case "$rel" in
    *'"'* | *'\'* | *$'\n'* | *'*'* | *'?'* | *'['*)
      fail "cannot upload \"$rel\": its name has a character SFTP treats specially." ;;
  esac
  printf 'put "%s" "%s/%s"\n' "$file" "$remote" "$rel" >> "$batch"
  file_count=$((file_count + 1))
done < <(find "$SOURCE_DIR" -type f -print0 | sort -z)

[ "$file_count" -gt 0 ] || fail "the \"$SOURCE_DIR\" folder has no files to upload."

if [ -n "${DRY_RUN:-}" ]; then
  say "Dry run. Nothing was uploaded. These commands would run on $SFTP_HOST:"
  sed 's/^/  /' "$batch"
  exit 0
fi

if ! sftp_run < "$batch" > "$work/upload_out" 2> "$work/upload_error"; then
  fail "the upload to \"$remote\" stopped part-way." "$(tr -d '\r' < "$work/upload_error" | tail -n 5)"
fi

say "Uploaded $file_count file(s) from $SOURCE_DIR/ to $remote on $SFTP_HOST."
if [ -f "$SOURCE_DIR/index.html" ]; then
  printf 'ls -l "%s/index.html"\n' "$remote" | sftp_run 2>/dev/null | grep -v '^sftp>' || true
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Deployed to SiteGround\n\n'
    # shellcheck disable=SC2016  # the backticks are Markdown, not shell
    printf 'Uploaded **%s** file(s) from `%s/` to `%s`.\n' "$file_count" "$SOURCE_DIR" "$remote"
  } >> "$GITHUB_STEP_SUMMARY"
fi
