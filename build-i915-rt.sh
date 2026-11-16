#!/usr/bin/env bash
set -euo pipefail

# The patchwork revisions below are based on drm-tip from around 2026-07-01;
# passing a newer BASE_REF may require conflict resolution in git am -3.
#
# Usage:
#   ./build-i915-rt.sh [BASE_REF]
#   ./build-i915-rt.sh --resume [BASE_REF]
#
# --resume continues an interrupted git am/merge from the current rt branch.
# Conflict resolutions are recorded by git rerere, and branches that already
# contain progress are reused instead of being recreated.

RESUME=0
if [[ "${1:-}" == "--resume" ]]; then
	RESUME=1
	shift
fi

BASE_REF="${1:-}"
if [[ -z "$BASE_REF" ]]; then
	if [[ $RESUME -eq 1 ]] && git rev-parse --verify -q refs/rt/base >/dev/null; then
		BASE_REF="$(git rev-parse refs/rt/base)"
	else
		BASE_REF="HEAD"
	fi
fi
BASE_SHA="$(git rev-parse --verify "${BASE_REF}^{commit}")"
git update-ref refs/rt/base "$BASE_SHA"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PATCHWORK="https://patchwork.freedesktop.org"

# Keep conflict resolutions for subsequent runs.
git config --local rerere.enabled true

echo "Base commit: $BASE_SHA ($BASE_REF)"
echo "Downloading mboxes..."

curl -fsSL -o "$WORKDIR/174789-v5.mbox" \
	"$PATCHWORK/api/1.0/series/174789/revisions/1/mbox/"
curl -fsSL -o "$WORKDIR/159035-v20.mbox" \
	"$PATCHWORK/api/1.0/series/159035/revisions/20/mbox/"

mkdir -p "$WORKDIR/split"
git mailsplit -o"$WORKDIR/split" "$WORKDIR/159035-v20.mbox" >/dev/null

# Return the path of the split patch whose Subject matches $1 as a literal
# substring.  Subjects may be folded over several header lines, so collect
# the whole header and normalize its whitespace first.
find_patch() {
	local subject="$1" f subject_line
	for f in "$WORKDIR"/split/*; do
		subject_line="$(
			awk '
				/^Subject:/ {
					subj = $0
					collecting = 1
					next
				}
				collecting && /^[ \t]/ {
					subj = subj " " $0
					next
				}
				collecting {
					collecting = 0
					exit
				}
				END {
					gsub(/[ \t]+/, " ", subj)
					print subj
				}
			' "$f"
		)"
		if grep -qF -- "$subject" <<<"$subject_line"; then
			printf '%s\n' "$f"
			return 0
		fi
	done
	return 1
}

am_by_subject() {
	local subject="$1" patch_file
	if ! patch_file="$(find_patch "$subject")"; then
		echo "ERROR: Could not find patch matching: $subject" >&2
		exit 1
	fi
	if is_patch_present "$patch_file"; then
		echo "  Already present (no changes): $subject"
		return 0
	fi
	echo "  Applying: $subject"
	if ! git am -3 "$patch_file"; then
		if am_in_progress; then
			report_am_failure "$patch_file"
			return 1
		fi
		report_am_failure "$patch_file"
		return 0
	fi
}

report_am_failure() {
	local patch_file="$1"
	if [[ -d "$(git rev-parse --git-path rebase-apply)" ]]; then
		echo "Patch does not apply: $patch_file" >&2
		echo "Resolve the conflicts, git add the files, then rerun with --resume." >&2
		return 1
	fi
	# git am refused the patch without starting to apply it, usually because
	# the change is already present. Treat that as already applied.
	echo "  Skipping (no changes to apply): $(sed -n 's/^Subject: //p' "$patch_file" | head -1)" >&2
	return 0
}

# Patchwork keeps sending patches that are already fully contained in the
# base (only context lines differ). Detect that before invoking git am, so the
# series does not stop on a conflict that has nothing left to change.
is_patch_present() {
	local patch_file="$1" out clean=0 conflicts=0
	out="$(git apply --3way --check "$patch_file" 2>&1)" || true
	clean=$(grep -c 'cleanly' <<<"$out")
	conflicts=$(grep -c 'with conflicts' <<<"$out")
	[[ "$clean" -eq 0 && "$conflicts" -gt 0 ]]
}

am_in_progress() {
	[[ -d "$(git rev-parse --git-path rebase-apply)" ]]
}

merge_in_progress() {
	[[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]]
}

has_unresolved_conflicts() {
	[[ -n "$(git diff --name-only --diff-filter=U)" ]]
}

continue_am_if_needed() {
	local patch_file
	while am_in_progress; do
		if has_unresolved_conflicts; then
			echo "ERROR: git am has unresolved conflicts." >&2
			echo "Resolve them, git add the files, then rerun with --resume." >&2
			exit 1
		fi
		if [[ -z "$(git diff --cached --name-only)" ]] && [[ -n "$(git rev-parse --git-path rebase-apply)" ]]; then
			patch_file="$(git rev-parse --git-path rebase-apply)/0001"
			if [[ -f "$patch_file" ]] && git diff HEAD --quiet; then
				echo "  Skipping (no changes to apply): $(sed -n 's/^Subject: //p' "$patch_file" | head -1)"
				git am --skip
				continue
			fi
		fi
		echo "Resuming interrupted git am..."
		if ! git am --continue; then
			if ! am_in_progress; then
				echo "  Skipping (no changes to apply) at $(git rev-parse --short HEAD)"
			else
				echo "ERROR: git am failed to continue." >&2
				exit 1
			fi
		fi
	done
}

continue_merge_if_needed() {
	if merge_in_progress; then
		if has_unresolved_conflicts; then
			echo "ERROR: merge has unresolved conflicts." >&2
			echo "Resolve them, git add the files, then rerun with --resume." >&2
			exit 1
		fi
		echo "Resuming interrupted merge..."
		git merge --continue
	fi
}

# Match on the patch title itself, not on the subject prefix (which carries
# the version, e.g. "[v10.5,06/29] ") or on continuation lines of subjects
# that git wraps on commit, so only real commits count as applied.
branch_has_subject() {
	local subject="$1"
	git log --no-merges --format=%s "$BASE_SHA..HEAD" >"$WORKDIR/subjects"
	grep -qxF -e "$subject" -e "[PATCH] $subject" "$WORKDIR/subjects"
}

apply_subject_if_needed() {
	local subject="$1"
	if branch_has_subject "$subject"; then
		echo "  Already applied: $subject"
		return 0
	fi
	am_by_subject "$subject"
}

CORE_SUBJECTS=(
	"drm/i915/gt: Use spin_lock_irq() instead of local_irq_disable() + spin_lock()"
	"drm/i915: Drop the irqs_disabled() check"
	"drm/i915/guc: Consider also RCU depth in busy loop."
	"drm/i915/gt: Fix selftests on PREEMPT_RT"
	"drm/i915/gt: Set stop_timeout() correctly on PREEMPT-RT"
	"drm/i915: Use sleeping selftests for igt_atomic on PREEMPT_RT"
)

DISPLAY_SUBJECTS=(
	"drm/vblank_work: Add methods to schedule vblank_work in 2 stages"
	"drm/vblank: Add a 2-stage version of drm_crtc_arm_vblank_event"
	"drm/intel/display: Make intel_crtc_arm_vblank_event static"
	"drm/intel/display: Convert vblank event handling to 2-stage arming"
	"drm/i915/display: Move vblank put until after critical section"
	"drm/i915/display: Remove locking from intel_vblank_evade critical section"
	"drm/i915/display: Handle vlv dsi workaround in scanline_in_safe_range too"
	"drm/i915: Use preempt_disable/enable_rt() where recommended"
	"drm/i915/display: Make get_vblank_counter use intel_de_read_fw()"
	"drm/i915/display: Do not take uncore lock in i915_get_vblank_counter"
	"drm/i915/display: Make icl_dsi_frame_update use _fw too"
	"drm/i915/display: Use intel_de_read/write_fw in colorops"
	"drm/i915/display: Use intel_de_write_fw in intel_pipe_fastset"
	"drm/i915/display: Make set_pipeconf use the fw variants"
	"drm/i915/display: Remove uncore lock from vlv_atomic_update_fifo"
)

# Never recreate a branch: that would discard commits already made on it.
# Only switch to it, creating it at the base when it does not exist yet.
prepare_branch() {
	local branch="$1"
	if [[ "$(git branch --show-current)" == "$branch" ]]; then
		return 0
	fi
	if git rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
		git checkout "$branch"
	else
		git checkout -b "$branch" "$BASE_SHA"
	fi
}

build_core() {
	echo "=== Building rt/i915-core ==="
	prepare_branch rt/i915-core
	continue_am_if_needed
	if [[ "$(git rev-list --count "$BASE_SHA..HEAD")" -eq 0 ]]; then
		if ! git am -3 "$WORKDIR/174789-v5.mbox"; then
			if am_in_progress; then
				report_am_failure "$WORKDIR/174789-v5.mbox"
				return 1
			fi
			report_am_failure "$WORKDIR/174789-v5.mbox"
		fi
	fi
	for subj in "${CORE_SUBJECTS[@]}"; do
		apply_subject_if_needed "$subj"
	done
	apply_subject_if_needed "drm/i915/gt: Add a spinlock to prevent starvation of irq_work."
}

build_display() {
	echo "=== Building rt/intel-display-vblank ==="
	prepare_branch rt/intel-display-vblank
	continue_am_if_needed
	for subj in "${DISPLAY_SUBJECTS[@]}"; do
		apply_subject_if_needed "$subj"
	done
}

build_pmu() {
	echo "=== Building rt/i915-pmu-kconfig ==="
	prepare_branch rt/i915-pmu-kconfig
	continue_am_if_needed

	if ! branch_has_subject "drm/i915/pmu: Disable on PREEMPT_RT"; then
		if ! PMU_PATCH="$(find_patch "drm/i915/pmu: Disable on PREEMPT_RT")"; then
			echo "ERROR: Could not find PMU patch" >&2
			exit 1
		fi
		sed -i 's/reeturn;/return;/' "$PMU_PATCH"
		if is_patch_present "$PMU_PATCH"; then
			echo "  Already present (no changes): drm/i915/pmu: Disable on PREEMPT_RT"
		elif ! git am -3 "$PMU_PATCH"; then
			report_am_failure "$PMU_PATCH" || exit 1
		fi
	fi
	apply_subject_if_needed 'Revert "drm/i915: Depend on !PREEMPT_RT."'
}

build_combined() {
	echo "=== Merging topic branches into rt/combined ==="
	prepare_branch rt/combined
	continue_merge_if_needed

	for branch in rt/i915-core rt/intel-display-vblank rt/i915-pmu-kconfig; do
		if ! git rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
			echo "ERROR: missing topic branch $branch; build it first" >&2
			exit 1
		fi
		if git merge-base --is-ancestor "$branch" HEAD; then
			echo "  Already merged: $branch"
		else
			git merge --no-ff -m "Merge branch '$branch' into rt/combined" "$branch"
		fi
	done

	echo "=== Done ==="
	git log --oneline --graph "$BASE_SHA..HEAD"
}

if am_in_progress || merge_in_progress; then
	if [[ $RESUME -eq 0 ]]; then
		echo "ERROR: an interrupted git am/merge is in progress." >&2
		echo "Resolve it and rerun with --resume, or use git am --abort." >&2
		exit 1
	fi
fi

if [[ $RESUME -eq 1 ]]; then
	case "$(git branch --show-current)" in
	rt/i915-core) START=core ;;
	rt/intel-display-vblank) START=display ;;
	rt/i915-pmu-kconfig) START=pmu ;;
	rt/combined) START=combined ;;
	*)
		# Nothing is in progress: continue from the first unfinished branch.
		if git rev-parse --verify -q refs/heads/rt/combined >/dev/null; then
			START=combined
		elif git rev-parse --verify -q refs/heads/rt/i915-pmu-kconfig >/dev/null; then
			START=pmu
		elif git rev-parse --verify -q refs/heads/rt/intel-display-vblank >/dev/null; then
			START=display
		else
			START=core
		fi
		echo "Resuming from $START branch"
		;;
	esac
else
	START=core
fi

case "$START" in
core)
	build_core
	build_display
	build_pmu
	build_combined
	;;
display)
	build_display
	build_pmu
	build_combined
	;;
pmu)
	build_pmu
	build_combined
	;;
combined)
	build_combined
	;;
esac
