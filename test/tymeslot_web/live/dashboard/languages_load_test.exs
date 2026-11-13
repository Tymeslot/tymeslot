defmodule TymeslotWeb.Dashboard.LanguagesLoadTest do
  @moduledoc """
  The Languages page reads everything translatable once per connected
  render, whatever the number of languages, counts every language's progress
  from that one read, skips it on the static render, and does not read it
  again after a translation is saved. Counted on the venues table, which
  `Tymeslot.ContentTranslations.Catalogue.items/1` reads once per call and
  saving a meeting type's translation does not touch.
  """
  # The query handler is global, so a concurrent test would add its own reads.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :i18n
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Repo

  setup :setup_dashboard_user

  setup %{user: user, profile: profile} do
    profile |> Changeset.change(translation_locales: ["de", "fr", "it"]) |> Repo.update!()
    insert(:venue, user: user, name: "Studio")
    meeting_type = insert(:meeting_type, user: user, name: "Intro call")

    parent = self()
    ref = make_ref()
    handler_id = "languages-load-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source == "venues", do: send(parent, {:venues_read, ref})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{ref: ref, meeting_type: meeting_type}
  end

  test "the settings page reads the items once for all its languages", %{conn: conn, ref: ref} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/languages")

    assert has_element?(view, "li[data-locale='it'] [data-testid='translation-progress']")
    assert reads(ref) == 1
  end

  test "the review page reads the items once, and not again after a save", %{
    conn: conn,
    ref: ref,
    meeting_type: meeting_type
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/languages/de")
    assert reads(ref) == 1

    view
    |> form("#translation-meeting_types-meeting_type-#{meeting_type.id}-form", %{
      "translation" => %{"name" => "Erstgespräch"}
    })
    |> render_submit()

    assert view |> element("[data-testid='translation-progress']") |> render() =~ "1/"
    assert reads(ref) == 0
  end

  defp reads(ref, count \\ 0) do
    receive do
      {:venues_read, ^ref} -> reads(ref, count + 1)
    after
      0 -> count
    end
  end
end
