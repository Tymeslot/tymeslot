defmodule TymeslotWeb.Themes.Shared.BookingSuccessHookElementTest do
  @moduledoc """
  Every theme's booking page carries the hidden `BookingSuccess` hook element
  (`Shared.SchedulingPage`), outside any step, so it is mounted when the page
  pushes `booking_success` on reaching the confirmation. On an embedded page it
  names the verified parent origin, the only origin the hook posts the booking
  to; on a page opened on its own it names none.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :themes
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  @parent_origin "https://embedder.test"
  @hook "#booking-success-hook[phx-hook='BookingSuccess']"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_all_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}" do
      setup do
        %{profile: profile} =
          seed_booking_account(unquote(theme.id), "success#{unquote(theme.id)}", "Etc/UTC")

        profile =
          profile
          |> Changeset.change(allowed_embed_domains: ["embedder.test"])
          |> Repo.update!()

        %{profile: profile}
      end

      test "an embedded page names the verified parent origin", %{conn: conn, profile: profile} do
        query = URI.encode_query(%{"embed" => "1", "parent-origin" => @parent_origin})
        {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")

        assert has_element?(view, "#{@hook}[data-parent-origin='#{@parent_origin}']")
      end

      test "a page opened on its own names no origin", %{conn: conn, profile: profile} do
        {:ok, view, _html} = live(conn, "/#{profile.username}")

        assert has_element?(view, @hook)
        refute has_element?(view, "#{@hook}[data-parent-origin]")
      end
    end
  end
end
