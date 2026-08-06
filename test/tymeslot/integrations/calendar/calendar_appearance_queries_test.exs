defmodule Tymeslot.Integrations.Calendar.CalendarAppearanceQueriesTest do
  @moduledoc """
  The per-calendar appearance store: upsert semantics, and the scoping that
  keeps one integration's choices out of another's.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarAppearanceQueries

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, is_active: true)
    {:ok, user: user, integration: integration}
  end

  describe "upsert/3" do
    test "creates a row on first write", %{integration: integration} do
      assert {:ok, appearance} =
               CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{colour: "banana"})

      assert appearance.colour == "banana"
      assert appearance.hidden == false
    end

    test "updates the existing row rather than inserting a second", %{integration: integration} do
      {:ok, _} = CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{colour: "banana"})
      {:ok, _} = CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{colour: "grape"})

      assert [%{colour: "grape"}] =
               CalendarAppearanceQueries.list_for_integrations([integration.id])
    end

    test "leaves hidden alone when only the colour is written", %{integration: integration} do
      {:ok, _} = CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{hidden: true})
      {:ok, _} = CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{colour: "sage"})

      assert [%{colour: "sage", hidden: true}] =
               CalendarAppearanceQueries.list_for_integrations([integration.id])
    end

    test "clearing the colour back to nil is allowed and means inherit", %{
      integration: integration
    } do
      {:ok, _} = CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{colour: "sage"})

      assert {:ok, %{colour: nil}} =
               CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{colour: nil})
    end

    test "rejects a colour outside the palette", %{integration: integration} do
      assert {:error, changeset} =
               CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{colour: "chartreuse"})

      assert "is not a palette colour" in errors_on(changeset).colour
    end

    test "keeps two calendars in one integration apart", %{integration: integration} do
      {:ok, _} = CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{colour: "sage"})
      {:ok, _} = CalendarAppearanceQueries.upsert(integration.id, "cal-2", %{colour: "grape"})

      colours =
        [integration.id]
        |> CalendarAppearanceQueries.list_for_integrations()
        |> Map.new(&{&1.provider_calendar_id, &1.colour})

      assert colours == %{"cal-1" => "sage", "cal-2" => "grape"}
    end
  end

  describe "list_for_integrations/1" do
    test "returns nothing for an integration with no choices", %{integration: integration} do
      assert CalendarAppearanceQueries.list_for_integrations([integration.id]) == []
    end

    test "does not leak another integration's rows", %{integration: integration} do
      other = insert(:calendar_integration, is_active: true)
      {:ok, _} = CalendarAppearanceQueries.upsert(other.id, "cal-1", %{colour: "tomato"})

      assert CalendarAppearanceQueries.list_for_integrations([integration.id]) == []
    end

    test "is empty for an empty id list", %{integration: integration} do
      {:ok, _} = CalendarAppearanceQueries.upsert(integration.id, "cal-1", %{colour: "tomato"})

      assert CalendarAppearanceQueries.list_for_integrations([]) == []
    end
  end
end
