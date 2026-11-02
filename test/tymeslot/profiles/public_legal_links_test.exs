defmodule Tymeslot.Profiles.PublicLegalLinksTest do
  use Tymeslot.DataCase, async: false

  @moduledoc """
  The legal links a booking page shows: the organiser's own, falling back per
  link to the instance default. The test sets application env, so it is not
  async.
  """
  @moduletag :profiles
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Profiles

  @default_notice "https://instance.example/notice"
  @default_privacy "https://instance.example/privacy"

  setup do
    old_notice = Application.get_env(:tymeslot, :booking_legal_notice_url)
    old_privacy = Application.get_env(:tymeslot, :booking_privacy_policy_url)

    on_exit(fn ->
      Application.put_env(:tymeslot, :booking_legal_notice_url, old_notice)
      Application.put_env(:tymeslot, :booking_privacy_policy_url, old_privacy)
    end)

    :ok
  end

  defp set_defaults(notice, privacy) do
    Application.put_env(:tymeslot, :booking_legal_notice_url, notice)
    Application.put_env(:tymeslot, :booking_privacy_policy_url, privacy)
  end

  test "returns the profile's links" do
    set_defaults(@default_notice, @default_privacy)

    profile =
      build(:profile,
        legal_notice_url: "https://me.example/impressum",
        privacy_policy_url: "https://me.example/privacy"
      )

    assert Profiles.public_legal_links(profile) == %{
             legal_notice_url: "https://me.example/impressum",
             privacy_policy_url: "https://me.example/privacy"
           }
  end

  test "falls back per link" do
    set_defaults(@default_notice, @default_privacy)
    profile = build(:profile, privacy_policy_url: "https://me.example/privacy")

    assert Profiles.public_legal_links(profile) == %{
             legal_notice_url: @default_notice,
             privacy_policy_url: "https://me.example/privacy"
           }
  end

  test "nil profile gives the instance defaults" do
    set_defaults(@default_notice, @default_privacy)

    assert Profiles.public_legal_links(nil) == %{
             legal_notice_url: @default_notice,
             privacy_policy_url: @default_privacy
           }
  end

  test "nothing set gives nil for both keys" do
    set_defaults(nil, nil)

    assert Profiles.public_legal_links(build(:profile)) == %{
             legal_notice_url: nil,
             privacy_policy_url: nil
           }
  end
end
