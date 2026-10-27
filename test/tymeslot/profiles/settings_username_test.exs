defmodule Tymeslot.Profiles.SettingsUsernameTest do
  @moduledoc """
  The onboarding form's username goes through `Profiles.change_username/2`,
  like the profile settings page's: rate limited when it changes, and able
  to publish the booking page.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :profiles

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Settings
  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    user = insert(:user)
    profile = insert(:profile, user: user, username: nil, timezone: "Europe/Berlin")
    %{user: user, profile: profile}
  end

  defp submit(profile, username),
    do: Settings.update_basic_settings(profile, %{"full_name" => "Ada", "username" => username})

  test "choosing a username publishes a page that has an active meeting type", %{
    user: user,
    profile: profile
  } do
    insert(:meeting_type, user: user, is_active: true)

    assert {:ok, %{username: "ada-host", full_name: "Ada"}} = submit(profile, "ada-host")
    assert %{booking_page_published_at: %DateTime{}} = Profiles.get_profile(user.id)
  end

  test "changing the username is rate limited", %{profile: profile} do
    final =
      Enum.reduce(1..6, profile, fn n, current ->
        {:ok, updated} = submit(current, "ada-host-#{n}")
        updated
      end)

    assert {:error, message} = submit(final, "ada-host-7")
    assert message =~ "Too many username change attempts"
  end

  test "re-submitting the same username costs nothing", %{profile: profile} do
    {:ok, named} = submit(profile, "ada-host")

    for _attempt <- 1..10, do: assert({:ok, _same} = submit(named, "ada-host"))
  end

  test "a reserved username is refused", %{profile: profile} do
    assert {:error, "This username is reserved"} = submit(profile, "dashboard")
  end

  # The name and time zone are checked first, so a refused one neither
  # writes the username nor spends a username change.
  test "a refused time zone writes nothing and spends no username change", %{
    user: user,
    profile: profile
  } do
    params = %{"full_name" => "Ada", "username" => "ada-host", "timezone" => "Not/AZone"}

    assert {:error, %Ecto.Changeset{}} = Settings.update_basic_settings(profile, params)
    assert Profiles.get_profile(user.id).username == nil

    final =
      Enum.reduce(1..6, profile, fn n, current ->
        {:ok, updated} = submit(current, "ada-#{n}")
        updated
      end)

    assert final.username == "ada-6"
  end
end
