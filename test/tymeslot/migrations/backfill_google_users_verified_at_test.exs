defmodule Tymeslot.Migrations.BackfillGoogleUsersVerifiedAtTest do
  @moduledoc """
  Value-correctness regression for
  `20260923100636_backfill_google_users_verified_at`: which social accounts it
  marks verified decides who can still sign in without an emailed link.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_923_100_636
  @inserted_at ~U[2026-05-01 09:00:00Z]

  test "stamps a Google account with the time it was created" do
    user = social_user(provider: "google", google_user_id: "g-1")

    MigrationRunner.replay!(@version)

    assert Repo.reload!(user).verified_at == @inserted_at
  end

  test "leaves GitHub and SSO accounts unverified" do
    github = social_user(provider: "github", github_user_id: "1")
    sso = social_user(provider: "oauth", provider_uid: "sub-1")

    MigrationRunner.replay!(@version)

    assert Repo.reload!(github).verified_at == nil
    assert Repo.reload!(sso).verified_at == nil
  end

  test "keeps an existing verified_at" do
    verified_at = ~U[2026-06-01 10:00:00Z]
    user = social_user(provider: "google", google_user_id: "g-2", verified_at: verified_at)

    MigrationRunner.replay!(@version)

    assert Repo.reload!(user).verified_at == verified_at
  end

  defp social_user(attrs) do
    insert(:user, Keyword.merge([verified_at: nil, inserted_at: @inserted_at], attrs))
  end
end
