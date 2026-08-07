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

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, is_active: true)
    {:ok, user: user, integration: integration}
  end

  describe "set_colour/4" do
    test "stores the choice", %{user: user, integration: integration} do
      assert {:ok, %{colour: "banana"}} =
               Appearance.set_colour(user.id, integration.id, "cal-1", "banana")
    end

    test "clearing to nil restores inheritance", %{user: user, integration: integration} do
      {:ok, _appearance} = Appearance.set_colour(user.id, integration.id, "cal-1", "banana")

      assert {:ok, %{colour: nil}} =
               Appearance.set_colour(user.id, integration.id, "cal-1", nil)
    end

    test "refuses an integration belonging to someone else", %{user: user} do
      other_integration = insert(:calendar_integration, is_active: true)

      assert {:error, :not_found} =
               Appearance.set_colour(user.id, other_integration.id, "cal-1", "banana")

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
    end
  end

  describe "list_for_user/1" do
    test "covers every active integration the user owns", %{user: user, integration: integration} do
      second = insert(:calendar_integration, user: user, is_active: true)
      {:ok, _appearance} = Appearance.set_colour(user.id, integration.id, "cal-1", "sage")
      {:ok, _appearance} = Appearance.set_colour(user.id, second.id, "cal-2", "grape")

      assert length(Appearance.list_for_user(user.id)) == 2
    end

    test "excludes another user's choices", %{user: user} do
      other_user = insert(:user)
      other_integration = insert(:calendar_integration, user: other_user, is_active: true)

      {:ok, _appearance} =
        Appearance.set_colour(other_user.id, other_integration.id, "cal-1", "sage")

      assert Appearance.list_for_user(user.id) == []
    end
  end

  describe "hidden_keys/1 and colour_keys/1" do
    test "key on the integration and calendar pair together", %{
      user: user,
      integration: integration
    } do
      {:ok, _appearance} = Appearance.set_hidden(user.id, integration.id, "cal-hidden", true)
      {:ok, _appearance} = Appearance.set_colour(user.id, integration.id, "cal-colour", "sage")

      appearances = Appearance.list_for_user(user.id)

      assert Appearance.hidden_keys(appearances) ==
               MapSet.new([{integration.id, "cal-hidden"}])

      assert Appearance.colour_keys(appearances) ==
               %{{integration.id, "cal-colour"} => "sage"}
    end

    test "a visibility-only row carries no colour", %{user: user, integration: integration} do
      {:ok, _appearance} = Appearance.set_hidden(user.id, integration.id, "cal-1", true)

      assert user.id |> Appearance.list_for_user() |> Appearance.colour_keys() == %{}
    end
  end
end
