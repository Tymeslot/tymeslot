defmodule TymeslotWeb.Live.Scheduling.EmbedQuestionAutofocusTest do
  @moduledoc """
  A browser refuses native `autofocus` inside a cross-origin frame and logs a
  console error on the embedding page for every attempt. A booking question
  inside an embed therefore renders without it, on every theme, while the
  page opened on its own keeps it.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  @question %{
    "id" => "af-company",
    "type" => "short_text",
    "label" => "Company",
    "required" => true,
    "position" => 0
  }
  @input "#cq-input-af-company"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    test "#{theme.name}: a question inside an embed takes no autofocus", %{conn: conn} do
      profile = seed(unquote(theme.id), "afembed#{unquote(theme.slug)}")

      conn = put_req_header(conn, "referer", "https://embedder.test/page")
      {:ok, view, _html} = live(conn, "/#{profile.username}?embed=1&timezone=UTC")
      assert :sys.get_state(view.pid).socket.assigns[:embedded] == true

      walk_to_question(view)

      refute has_element?(view, "#{@input}[autofocus]")
    end
  end

  test "Quill: the same question on the page opened on its own keeps its autofocus", %{
    conn: conn
  } do
    profile = seed("1", "afstandalone")

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=UTC")
    walk_to_question(view)

    assert has_element?(view, "#{@input}[autofocus]")
  end

  defp seed(theme_id, username) do
    %{profile: profile} =
      seed_organiser(theme_id, username,
        profile: [allowed_embed_domains: ["embedder.test"]],
        types: [[name: "Quick Chat", duration_minutes: 30, custom_fields: [@question]]]
      )

    profile
  end

  # Chooses the type and the first free time, then moves on until the
  # question is on show (a paged theme asks it on a step of its own).
  defp walk_to_question(view) do
    BookingDriver.choose_meeting_type(view, "quick-chat")
    BookingDriver.pick_first_slot(view)
    continue_until_question(view, 3)
  end

  defp continue_until_question(view, moves_left) do
    cond do
      has_element?(view, @input) ->
        :ok

      moves_left == 0 ->
        flunk("the question never came into view")

      true ->
        BookingDriver.continue(view)
        continue_until_question(view, moves_left - 1)
    end
  end
end
