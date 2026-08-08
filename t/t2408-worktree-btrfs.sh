#!/bin/sh

test_description='test AWACS-backed git worktree forwarding'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

TEST_CREATE_REPO_NO_TEMPLATE=1
. ./test-lib.sh

FAKE_AWACS_LOG="$TRASH_DIRECTORY/.git/fake-awacs.log"
PATH="$TRASH_DIRECTORY/.git/fake-bin:$PATH"
export FAKE_AWACS_LOG PATH

test_expect_success 'setup repository and fake awacs' '
	test_commit first tracked first &&
	echo second >tracked &&
	git commit -am second &&
	mkdir -p .git/fake-bin &&
	write_script .git/fake-bin/awacs <<-\EOF
	printf "%s\n" "$*" >>"$FAKE_AWACS_LOG"
	test "$1 $2" = "git worktree-add" || {
		test "$1 $2" = "git worktree-remove" || exit 1
		shift 2
		test "$1" = --path || exit 1
		rm -rf "$2"
		exit 0
	}
	shift 2
	required=
	detach=
	check_only=
	no_check=
	source=
	destination=
	ref=
	while test "$#" -gt 0
	do
		case "$1" in
		--git) shift 2 ;;
		--source) source=$2; shift 2 ;;
		--destination) destination=$2; shift 2 ;;
		--ref) ref=$2; shift 2 ;;
		--required) required=t; shift ;;
		--detach) detach=--detach; shift ;;
		--check-only) check_only=t; shift ;;
		--no-check) no_check=t; shift ;;
		--force|--relative-paths|--quiet) shift ;;
		--lock-reason) shift 2 ;;
		*) exit 1 ;;
		esac
	done
	if test "$FAKE_AWACS_INELIGIBLE" = true && test -n "$required"
	then
		echo "source worktree is not a Btrfs subvolume" >&2
		exit 1
	fi
	test -n "$check_only" && exit 0
	GIT_AWACS_BYPASS=1 git -C "$source" worktree add --no-btrfs-snapshot $detach "$destination" "$ref" || exit 1
	if test "$FAKE_AWACS_FAIL_AFTER_REGISTER" = true
	then
		GIT_AWACS_BYPASS=1 git -C "$source" worktree remove --force "$destination" || exit 1
		exit 1
	fi
	if test "$FAKE_AWACS_INELIGIBLE" != true
	then
		marker=$(git -C "$destination" rev-parse --git-path awacs-worktree) || exit 1
		: >"$marker"
	fi
	EOF
'

test_expect_success 'snapshot mode defaults to false' '
	rm -f "$FAKE_AWACS_LOG" &&
	git worktree add --detach normal HEAD &&
	test_path_is_missing "$FAKE_AWACS_LOG" &&
	git worktree remove normal
'

test_expect_success 'true forwards normalized add request to awacs' '
	rm -f "$FAKE_AWACS_LOG" &&
	git -c worktree.btrfsSnapshot=true worktree add --detach ../snapshot HEAD^ &&
	test_grep "git worktree-add" "$FAKE_AWACS_LOG" &&
	test_grep -- "--required" "$FAKE_AWACS_LOG" &&
	test_grep -- "--source $PWD" "$FAKE_AWACS_LOG" &&
	test_grep -- "--destination ../snapshot" "$FAKE_AWACS_LOG" &&
	test_path_is_file .git/worktrees/snapshot/awacs-worktree &&
	echo first >.git/expect &&
	test_cmp .git/expect ../snapshot/tracked
'

test_expect_success 'marked remove forwards physical deletion to awacs' '
	rm -f "$FAKE_AWACS_LOG" &&
	git worktree remove ../snapshot &&
	test_grep "git worktree-remove --path" "$FAKE_AWACS_LOG" &&
	test_path_is_missing ../snapshot &&
	test_path_is_missing .git/worktrees/snapshot
'

test_expect_success 'auto fallback is owned by awacs' '
	rm -f "$FAKE_AWACS_LOG" &&
	FAKE_AWACS_INELIGIBLE=true git -c worktree.btrfsSnapshot=auto worktree add --detach ../fallback HEAD &&
	test_grep "git worktree-add" "$FAKE_AWACS_LOG" &&
	test_path_is_missing .git/worktrees/fallback/awacs-worktree &&
	git worktree remove ../fallback
'

test_expect_success 'required mode reports awacs eligibility failure' '
	test_must_fail env FAKE_AWACS_INELIGIBLE=true git -c worktree.btrfsSnapshot=true worktree add --detach ../required HEAD 2>.git/err &&
	test_grep "source worktree is not a Btrfs subvolume" .git/err &&
	test_path_is_missing ../required
'

test_expect_success 'required preflight does not leave an inferred branch' '
	test_must_fail env FAKE_AWACS_INELIGIBLE=true git -c worktree.btrfsSnapshot=true worktree add ../preflight-failure 2>.git/err &&
	test_grep "source worktree is not a Btrfs subvolume" .git/err &&
	test_must_fail git show-ref --verify refs/heads/preflight-failure &&
	test_path_is_missing ../preflight-failure
'

test_expect_success 'delegated failure rolls back an inferred branch' '
	rm -f "$FAKE_AWACS_LOG" &&
	test_must_fail env FAKE_AWACS_FAIL_AFTER_REGISTER=true git -c worktree.btrfsSnapshot=true worktree add ../delegated-failure 2>.git/err &&
	test_grep -- "--no-check" "$FAKE_AWACS_LOG" &&
	test_must_fail git show-ref --verify refs/heads/delegated-failure &&
	test_path_is_missing ../delegated-failure
'

test_expect_success '--no-btrfs-snapshot overrides true config' '
	rm -f "$FAKE_AWACS_LOG" &&
	git -c worktree.btrfsSnapshot=true worktree add --detach --no-btrfs-snapshot disabled HEAD &&
	test_path_is_missing "$FAKE_AWACS_LOG" &&
	git worktree remove disabled
'

test_expect_success 'invalid config values and valued CLI option are rejected' '
	test_must_fail git -c worktree.btrfsSnapshot=bogus worktree add --detach invalid-config HEAD 2>.git/err &&
	test_grep "invalid value for.*worktree.btrfssnapshot" .git/err &&
	test_must_fail git worktree add --detach --btrfs-snapshot=auto invalid-option HEAD 2>.git/err &&
	test_grep "takes no value" .git/err
'

test_done
