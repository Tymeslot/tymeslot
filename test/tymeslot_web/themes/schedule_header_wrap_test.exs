defmodule TymeslotWeb.Themes.ScheduleHeaderWrapTest do
  @moduledoc """
  Keeps the schedule step's heading readable beside the time zone trigger on a
  phone.

  The trigger shows the visitor's zone by name ("New York, United States"), so
  it can take most of a phone-width card. Quill once kept it on the heading's
  row whatever its width, squeezing the heading into a column too narrow for a
  single word ("Sélection / ner une / date et / une / heure" in French), and
  Rhythm pinned it to the header's corner over the organiser's name. Quill's
  header now wraps the trigger under the heading once the heading would fall
  below its basis, and Rhythm's stacked phone header keeps the trigger in the
  flow, under the organiser.

  The layout itself is CSS, so beside the rendered markup these tests pin the
  rules that make the row wrap, rather than measuring pixels.
  """

  # The CSS tests guard shipped stylesheets, not application code.
  # credo:disable-for-this-file Jump.CredoChecks.VacuousTest

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SlotPickerTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @quill_header_css "assets/css/scheduling/themes/quill/modules/schedule-header.css"
  @rhythm_header_css "assets/css/scheduling/themes/rhythm/modules/schedule-header.css"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    :ok
  end

  describe "Quill" do
    @tag :capture_log
    test "renders the heading and the time zone trigger as separate items of the header row",
         %{conn: conn} do
      %{user: user, profile: profile} = booking_page("quillheader", "1")
      insert(:meeting_type, user: user, name: "Intro Call", duration_minutes: 30, is_active: true)
      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=America/New_York")

      [duration | _others] = BookingDriver.meeting_types(view)
      BookingDriver.choose_meeting_type(view, duration)
      BookingDriver.continue(view)

      doc = document(view)

      assert [_heading] = Floki.find(doc, ".schedule-card-header > .schedule-title-area h1")

      assert [_picker] =
               Floki.find(doc, ".schedule-card-header > .schedule-timezone-area .tz-picker")
    end

    test "wraps the header row, and gives the title a basis to wrap at" do
      css = File.read!(@quill_header_css)

      assert rule(css, ".schedule-card-header") =~ ~r/flex-wrap:\s*wrap/

      # `flex-1` (a zero basis) lets the title shrink to nothing before the row
      # wraps; the basis is what makes the trigger move down instead.
      assert [_match, basis] =
               Regex.run(~r/flex:\s*1 1 ([^;]+);/, rule(css, ".schedule-title-area"))

      assert basis =~ ~r/^[1-9][0-9.]*rem$/
    end
  end

  describe "Rhythm" do
    test "keeps the time zone trigger in the flow of the stacked phone header" do
      css = File.read!(@rhythm_header_css)

      [_match, phone] =
        Regex.run(~r/@container scheduling \(max-width: 479px\) \{(.*?)\n\}/s, css)

      assert rule(phone, ".timezone-selector-container") =~ ~r/position:\s*static/
    end
  end

  # The declarations of the first rule whose selector is exactly `selector`.
  defp rule(css, selector) do
    pattern = ~r/(?:^|\n)\s*#{Regex.escape(selector)}\s*\{([^}]*)\}/

    case Regex.run(pattern, css) do
      [_match, body] -> body
      nil -> flunk("no #{selector} rule found")
    end
  end
end
