#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

command="$ROOT/bin/omarchy-kernel"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/root-bin" "$scratch/drop-ins" "$scratch/modules"

export PATH="$scratch/bin:$PATH"
export CALL_LOG="$scratch/calls"
export OMARCHY_PATH="$ROOT"
export OMARCHY_KERNEL_LIMINE_CONF="$scratch/limine"
export OMARCHY_KERNEL_LIMINE_DROP_INS="$scratch/drop-ins"
export OMARCHY_KERNEL_MODULES_DIR="$scratch/modules"
export OMARCHY_KERNEL_ROOT_PATH="$scratch/root-bin:/usr/bin:/bin"

install_kernels() {
  local kernel
  rm -rf "$scratch/modules/"*
  for kernel in "$@"; do
    mkdir -p "$scratch/modules/$kernel-version"
    printf '%s\n' "$kernel" > "$scratch/modules/$kernel-version/pkgbase"
  done
}

# Unprivileged side: escalation records what it would run instead of running it.
for tool in pkexec sudo omarchy-state omarchy-notification-send; do
  cat > "$scratch/bin/$tool" <<SH
#!/bin/bash
printf '$tool %s\n' "\$*" >> "\$CALL_LOG"
[[ \${ESCALATION_FAIL:-0} == "0" || $tool != "pkexec" ]]
SH
done

# Root side: the rebuild writes a menu in BOOT_ORDER order, as limine-entry-tool does.
cat > "$scratch/root-bin/limine-mkinitcpio" <<'SH'
#!/bin/bash
printf 'limine-mkinitcpio %s\n' "$*" >> "$CALL_LOG"
[[ ${REBUILD_FAIL:-0} == "0" ]]
SH
cat > "$scratch/root-bin/limine-entry-tool" <<'SH'
#!/bin/bash
[[ $* == "--tree" ]] || exit 99
printf '%s\n' 'Omarchy'
printf '├─ %s\n' ${MENU_ORDER:-linux-omarchy linux}
printf '%s\n' '└─ Snapshots' '   └─ 52 │ 2026-10-19 20:33:31'
SH
chmod +x "$scratch/bin/"* "$scratch/root-bin/"*

reset_fixture() {
  : > "$CALL_LOG"
  rm -f "$scratch/drop-ins/"*
  install_kernels linux linux-omarchy linux-omarchy-bore-o3-exp
  cat > "$OMARCHY_KERNEL_LIMINE_CONF" <<'CONF'
KERNEL_CMDLINE[default]+="root=/dev/mapper/root rw"
BOOT_ORDER="linux-omarchy-bore-o3-exp, linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"
CONF
}

as_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    unshare --user --map-root-user "$@"
  fi
}

reset_fixture
[[ $("$command" list) == $'linux\nlinux-omarchy\nlinux-omarchy-bore-o3-exp' ]] || fail "list prints each installed kernel once"
[[ $("$command" get) == "linux-omarchy-bore-o3-exp" ]] || fail "get reads the central boot order"
[[ $("$command") == "linux-omarchy-bore-o3-exp" ]] || fail "get is the default verb"
pass "list and get read installed kernels and the boot order"

reset_fixture
sed -i '/^BOOT_ORDER=/d' "$OMARCHY_KERNEL_LIMINE_CONF"
printf '%s\n' 'BOOT_ORDER="linux-t2, linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"' > "$scratch/drop-ins/omarchy-defaults.conf"
[[ $("$command" get) == "linux-omarchy" ]] || fail "a drop-in order applies when the central config has none"
printf '%s\n' "BOOT_ORDER='linux, *'" > "$scratch/drop-ins/zz-local.conf"
[[ $("$command" get) == "linux" ]] || fail "the last drop-in read wins"
printf '%s\n' 'BOOT_ORDER="linux-omarchy-*, *"' >> "$OMARCHY_KERNEL_LIMINE_CONF"
[[ $("$command" get) == "linux-omarchy-bore-o3-exp" ]] || fail "the central config wins over drop-ins, and globs match"
pass "get resolves the effective order the way limine-entry-tool reads it"

reset_fixture
install_kernels linux linux-omarchy-bore linux-omarchy-bore-o3-exp
printf '%s\n' 'BOOT_ORDER="linux-omarchy-*, *"' >> "$OMARCHY_KERNEL_LIMINE_CONF"
if "$command" get > "$scratch/output" 2> "$scratch/errors"; then
  fail "a wildcard that matches several kernels cannot name the default"
fi
[[ ! -s $scratch/output ]] || fail "an ambiguous default prints no kernel, so no menu row is checked" "$(<"$scratch/output")"
grep -Fq "matches linux-omarchy-bore linux-omarchy-bore-o3-exp" "$scratch/errors" || fail "the ambiguity names the kernels" "$(<"$scratch/errors")"
pass "get does not guess between kernels a wildcard ties"

reset_fixture
if "$command" set linux-lts 2> "$scratch/output"; then
  fail "a kernel that is not installed is refused"
fi
grep -Fq "linux-lts is not an installed kernel" "$scratch/output" || fail "the refusal names the kernel" "$(<"$scratch/output")"
[[ ! -s $CALL_LOG ]] || fail "a refused kernel never escalates" "$(<"$CALL_LOG")"
pass "set only accepts installed kernels"

reset_fixture
"$command" set linux-omarchy < /dev/null
[[ $(grep -c '^pkexec ' "$CALL_LOG") == "1" ]] || fail "the menu path escalates through pkexec once" "$(<"$CALL_LOG")"
grep -Fxq "pkexec $ROOT/bin/omarchy-kernel set linux-omarchy" "$CALL_LOG" || fail "pkexec runs this command's root half" "$(<"$CALL_LOG")"
! grep -q '^sudo ' "$CALL_LOG" || fail "the menu path has no terminal for sudo"
grep -Fxq 'omarchy-state set reboot-required' "$CALL_LOG" || fail "a switch asks for a reboot"
[[ $(grep -c '^omarchy-notification-send ' "$CALL_LOG") == "1" ]] || fail "only the finished switch is announced" "$(<"$CALL_LOG")"
pass "picked from the menu, set authenticates once with pkexec and asks for a reboot"

reset_fixture
if ESCALATION_FAIL=1 "$command" set linux-omarchy < /dev/null; then
  fail "a cancelled prompt fails the switch"
fi
! grep -q '^omarchy-state ' "$CALL_LOG" || fail "a cancelled switch does not ask for a reboot"
grep -q '^omarchy-notification-send .*-u critical' "$CALL_LOG" || fail "a cancelled switch says so" "$(<"$CALL_LOG")"
pass "a cancelled or failed pkexec leaves no reboot request"

if (( EUID != 0 )) && ! unshare --user --map-root-user true 2>/dev/null; then
  skip "root half needs a user namespace"
  exit 0
fi

reset_fixture
MENU_ORDER="linux linux-omarchy linux-omarchy-bore-o3-exp" as_root "$command" set linux
[[ $(grep -c '^BOOT_ORDER=' "$OMARCHY_KERNEL_LIMINE_CONF") == "1" ]] || fail "one boot order remains"
grep -Fxq 'BOOT_ORDER="linux, linux-omarchy-bore-o3-exp, linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"' "$OMARCHY_KERNEL_LIMINE_CONF" ||
  fail "the kernel goes first and the rest of the order follows" "$(<"$OMARCHY_KERNEL_LIMINE_CONF")"
grep -Fxq 'KERNEL_CMDLINE[default]+="root=/dev/mapper/root rw"' "$OMARCHY_KERNEL_LIMINE_CONF" || fail "the kernel cmdline is preserved"
grep -Fxq 'limine-mkinitcpio linux' "$CALL_LOG" || fail "only the chosen kernel is rebuilt" "$(<"$CALL_LOG")"
[[ $("$command" get) == "linux" ]] || fail "get reports the new default"
pass "the root half puts the kernel first, keeps other settings, and rebuilds one kernel"

reset_fixture
MENU_ORDER="linux-omarchy linux linux-omarchy-bore-o3-exp" as_root "$command" set linux-omarchy
MENU_ORDER="linux-omarchy linux linux-omarchy-bore-o3-exp" as_root "$command" set linux-omarchy
grep -Fxq 'BOOT_ORDER="linux-omarchy, linux-omarchy-bore-o3-exp, linux-omarchy-*, *, *fallback, Snapshots"' "$OMARCHY_KERNEL_LIMINE_CONF" ||
  fail "setting the same kernel twice does not repeat it" "$(<"$OMARCHY_KERNEL_LIMINE_CONF")"
! grep -q '^$' "$OMARCHY_KERNEL_LIMINE_CONF" || fail "repeated switches do not pile up blank lines"
pass "switching is idempotent"

reset_fixture
cp "$OMARCHY_KERNEL_LIMINE_CONF" "$scratch/original-limine"
if MENU_ORDER="linux-omarchy-bore-o3-exp linux linux-omarchy" as_root "$command" set linux 2> "$scratch/output"; then
  fail "a menu that did not reorder fails the switch"
fi
grep -Fq "linux did not become the first boot entry" "$scratch/output" || fail "the failure says the menu was not reordered" "$(<"$scratch/output")"
cmp -s "$OMARCHY_KERNEL_LIMINE_CONF" "$scratch/original-limine" || fail "a skipped build restores the previous boot order" "$(<"$OMARCHY_KERNEL_LIMINE_CONF")"
pass "a skipped boot image build fails and puts the previous boot order back"

reset_fixture
if REBUILD_FAIL=1 MENU_ORDER="linux linux-omarchy" as_root "$command" set linux 2> "$scratch/output"; then
  fail "a failed rebuild fails the switch"
fi
cmp -s "$OMARCHY_KERNEL_LIMINE_CONF" "$scratch/original-limine" || fail "a failed rebuild restores the previous boot order" "$(<"$OMARCHY_KERNEL_LIMINE_CONF")"
[[ $("$command" get) == "linux-omarchy-bore-o3-exp" ]] || fail "get still reports the previous default after a failed switch"
pass "a failed rebuild leaves the previous default in place"
