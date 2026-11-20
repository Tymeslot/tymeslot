defmodule Tymeslot.Integrations.Calendar.AppearanceTest do
  @moduledoc """
  The per-calendar appearance API, including the ownership check that stands
  between a forged integration id and another organiser's calendar.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Security.RateLimiter

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, is_active: true)
    {:ok, user: user, integration: integration}
  end

  describe "set_colour/4" do
    test "stores the choice", %{user: user, integration: integration} do
      assert {:ok, %{colour: "banana"}} =
               Appearance.set_colour(user.id, integration.id, "cal-1", "banana")

      assert Appearance.colour_keys(Appearance.list_for_user(user.id)) ==
               %{{integration.id, "cal-1"} => "banana"}
    end

    test "clearing to nil restores inheritance", %{user: user, integration: integration} do
      {:ok, _appearance} = Appearance.set_colour(user.id, integration.id, "cal-1", "banana")

      assert {:ok, %{colour: nil}} =
               Appearance.set_colour(user.id, integration.id, "cal-1", nil)

      assert Appearance.colour_keys(Appearance.list_for_user(user.id)) == %{}
    end

    test "refuses a colour outside the palette", %{user: user, integration: integration} do
      assert {:error, %Ecto.Changeset{}} =
               Appearance.set_colour(user.id, integration.id, "cal-1", "#ff0000")
    end

    test "refuses an integration belonging to someone else", %{user: user} do
      other_integration = insert(:calendar_integration, is_active: true)

      assert {:error, :not_found} =
               Appearance.set_colour(user.id, other_integration.id, "cal-1", "banana")

      assert Appearance.list_for_user(user.id) == []
    end

    test "is charged to the appearance budget", %{user: user, integration: integration} do
      for _attempt <- 1..150, do: :ok = RateLimiter.check(:integration_appearance, user.id)

      assert {:error, {:rate_limited, _message}} =
               Appearance.set_colour(user.id, integration.id, "cal-1", "banana")

      assert Appearance.list_for_user(user.id) == []
    end
  end

  describe "set_hidden/4" do
    test "hides and shows one calendar", %{user: user, integration: integration} do
      assert {:ok, %{hidden: true}} =
               Appearance.set_hidden(user.id, integration.id, "cal-1", true)

      assert {:ok, %{hidden: false}} =
               Appearance.set_hidden(user.id, integration.id, "cal-1", false)
    end

    test "refuses an integration belonging to someone else", %{user: user} do
      other_integration = insert(:calendar_integration, is_active: true)

      assert {:error, :not_found} =
               Appearance.set_hidden(user.id, other_integration.id, "cal-1", true)

      assert Appearance.list_for_user(user.id) == []
    end
  end

  describe "list_for_user/1" do
    test "covers every active integration the user owns", %{user: user, integration: integration} do
      second = insert(:calendar_integration, user: user, is_active: true)
      {:ok, _appearance} = Appearance.set_hidden(user.id, integration.id, "cal-1", true)
      {:ok, _appearance} = Appearance.set_hidden(user.id, second.id, "cal-2", true)

      assert length(Appearance.list_for_user(user.id)) == 2
    end

    test "excludes another user's choices", %{user: user} do
      other_user = insert(:user)
      other_integration = insert(:calendar_integration, user: other_user, is_active: true)

      {:ok, _appearance} =
        Appearance.set_hidden(other_user.id, other_integration.id, "cal-1", true)

      assert Appearance.list_for_user(user.id) == []
    end
  end

  describe "hidden_keys/1" do
    test "keys a hidden calendar on the integration and calendar pair", %{
      user: user,
      integration: integration
    } do
      {:ok, _appearance} = Appearance.set_hidden(user.id, integration.id, "cal-hidden", true)
      {:ok, _appearance} = Appearance.set_hidden(user.id, integration.id, "cal-shown", false)

      assert user.id |> Appearance.list_for_user() |> Appearance.hidden_keys() ==
               MapSet.new([{integration.id, "cal-hidden"}])
    end
  end

  describe "chosen?/1" do
    test "a visibility-only row carries no colour", %{user: user, integration: integration} do
      {:ok, appearance} = Appearance.set_hidden(user.id, integration.id, "cal-1", true)

      refute Appearance.chosen?(appearance)
      assert Appearance.chosen?(%{appearance | colour: "sage"})
    end
  end
end
