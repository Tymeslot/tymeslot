defmodule Tymeslot.Profiles.SuggestUsernameTest do
  @moduledoc """
  The booking link suggested from a host's name: normalised, valid, not
  reserved and not taken.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :unit

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Profiles.ReservedPaths
  alias Tymeslot.Repo

  @user_id 4242

  test "Anna Kowalska becomes anna-kowalska" do
    assert Profiles.suggest_username("Anna Kowalska", @user_id) == "anna-kowalska"
  end

  test "diacritics are folded" do
    assert Profiles.suggest_username("José Núñez", @user_id) == "jose-nunez"
  end

  test "letters without a decomposition are dropped" do
    assert Profiles.suggest_username("Zoë Łukasiewicz", @user_id) == "zoe-ukasiewicz"
    assert Profiles.suggest_username("Straße", @user_id) == "stra-e"
  end

  test "a taken name gets a number" do
    insert(:profile, username: "anna-kowalska")

    assert Profiles.suggest_username("Anna Kowalska", @user_id) == "anna-kowalska-2"
  end

  test "the first free number is used" do
    insert(:profile, username: "anna-kowalska")
    insert(:profile, username: "anna-kowalska-2")
    insert(:profile, username: "anna-kowalska-3")

    assert Profiles.suggest_username("Anna Kowalska", @user_id) == "anna-kowalska-4"
  end

  test "a reserved word is skipped" do
    assert ReservedPaths.reserved?("admin")
    refute ReservedPaths.reserved?("admin-2")

    assert Profiles.suggest_username("Admin", @user_id) == "admin-2"
  end

  test "a blank or one-letter name falls back to the user id" do
    expected = "user-#{@user_id}"

    assert Profiles.suggest_username(nil, @user_id) == expected
    assert Profiles.suggest_username("", @user_id) == expected
    assert Profiles.suggest_username("   ", @user_id) == expected
    assert Profiles.suggest_username("Ö", @user_id) == expected
  end

  test "emoji-only names fall back" do
    assert Profiles.suggest_username("🙂🙂", @user_id) == "user-#{@user_id}"
  end

  test "long names are cut to 30 characters" do
    suggestion = Profiles.suggest_username(String.duplicate("abcdefghi ", 6), @user_id)

    assert suggestion == "abcdefghi-abcdefghi-abcdefghi"
    assert String.length(suggestion) <= 30
  end

  test "a long taken name keeps the suffix within 30 characters" do
    base = "abcdefghi-abcdefghi-abcdefghi"
    insert(:profile, username: base)

    suggestion = Profiles.suggest_username(String.duplicate("abcdefghi ", 6), @user_id)

    assert suggestion == "abcdefghi-abcdefghi-abcdefgh-2"
    assert String.length(suggestion) == 30
  end

  test "all nine numbered candidates taken falls back to the name and user id" do
    insert(:profile, username: "anna-kowalska")
    for n <- 2..9, do: insert(:profile, username: "anna-kowalska-#{n}")

    assert Profiles.suggest_username("Anna Kowalska", @user_id) == "anna-kowalska-#{@user_id}"
  end

  test "a blank name falls back to the email's local part" do
    assert Profiles.suggest_username(nil, @user_id, email: "anna.k+work@example.com") == "anna-k"
    assert Profiles.suggest_username("  ", @user_id, email: "anna.k@example.com") == "anna-k"
  end

  test "a name wins over the email" do
    assert Profiles.suggest_username("Jan Nowak", @user_id, email: "anna@example.com") ==
             "jan-nowak"
  end

  test "a short email local part falls back to the user id" do
    assert Profiles.suggest_username(nil, @user_id, email: "ab@example.com") == "user-#{@user_id}"
  end

  describe "default_username?/2" do
    test "blank and the generated default are no choice of the host's" do
      assert Profiles.default_username?(nil, @user_id)
      assert Profiles.default_username?("", @user_id)
      assert Profiles.default_username?("user_#{@user_id}", @user_id)
      assert Profiles.default_username?("user_#{@user_id}_0a1b2c3d", @user_id)
    end

    test "a chosen username, or another user's default, is not" do
      refute Profiles.default_username?("anna-kowalska", @user_id)
      refute Profiles.default_username?("user_1", @user_id)
      refute Profiles.default_username?("user-#{@user_id}", @user_id)
    end
  end

  test "it writes nothing" do
    before_count = Repo.aggregate(ProfileSchema, :count)
    Profiles.suggest_username("Anna Kowalska", @user_id)

    assert Repo.aggregate(ProfileSchema, :count) == before_count
  end
end
