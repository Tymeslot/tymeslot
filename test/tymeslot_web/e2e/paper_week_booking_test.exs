defmodule TymeslotWeb.E2E.PaperWeekBookingTest do
  @moduledoc """
  Bookings through Paper's week view (its calendar view option set to
  `week`) in a real browser, where the grid loads its week by itself: on a
  phone, where three days are in view and the rest scroll sideways, and
  framed in an inline embed in the column layout, where all seven days sit
  side by side under the compact details. The embed is framed through the
  embed token (`?embed=1` with `parent-origin`) on a same-origin host page,
  with the host page's own origin as the parent origin so that the heights
  the frame posts reach it. Each journey ends in the database, at the day
  and time the visitor clicked.
  """
  use TymeslotWeb.BrowserCase, async: false

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias TymeslotWeb.Endpoint
  alias Wallaby.Element

  @moduletag :e2e
  @moduletag :themes

  @free_slot "[data-testid='week-slot']:not([disabled])"

  feature "a visitor books through Paper's week view on a phone", %{session: session} do
    profile = create_paper_week_profile()

    session =
      session
      |> resize_window(390, 844)
      |> visit("/#{profile.username}")
      |> wait_for_live()
      |> advance_to_schedule()
      |> assert_has(css(@free_slot, minimum: 1))
      |> assert_no_horizontal_overflow("Paper week view at 390px")

    assert page_scroll_width(session) <= 390
    assert days_in_view(session) == 3
    assert details_above_week?(session)
    assert truncated_slots(session) == 0

    {date, time} = book(session, "paper-phone@example.com")

    assert_booked_at("paper-phone@example.com", date, time)
  end

  feature "a visitor books through Paper's week view framed in an inline embed",
          %{session: session} do
    profile = create_paper_week_profile()

    path =
      "/#{profile.username}?" <>
        URI.encode_query(%{
          "embed" => "1",
          "parent-origin" => host_origin(),
          "theme" => "3",
          "layout" => "column"
        })

    session =
      session
      |> resize_window(1280, 900)
      |> visit("/#{profile.username}")
      |> frame(path, "1000px")
      |> assert_has(css("html[data-embedded][data-embed-layout='column']"))
      |> advance_to_schedule()
      |> assert_has(css(@free_slot, minimum: 1))
      |> assert_no_horizontal_overflow("Paper week view in a 1000px embed")

    assert page_scroll_width(session) <= 1000
    assert days_in_view(session) == 7
    assert details_above_week?(session)
    assert truncated_slots(session) == 0

    {date, time} =
      book(session, "paper-embed@example.com", &assert_posted_height_covers_next/1)

    assert_booked_at("paper-embed@example.com", date, time)
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  defp create_paper_week_profile do
    user = create_onboarded_user()
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, _meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Paper Intro Call",
        duration_minutes: 30,
        is_active: true
      })

    profile =
      user.id
      |> Profiles.get_profile()
      |> Changeset.change(
        booking_theme: "3",
        allowed_embed_domains: [URI.parse(host_origin()).host]
      )
      |> Repo.update!()

    insert(:theme_customization,
      profile: profile,
      theme_id: "3",
      settings: %{"calendar_view" => "week"}
    )

    profile
  end

  # ── Navigation ─────────────────────────────────────────────────────────

  defp advance_to_schedule(session) do
    session
    |> find(css("[data-testid='duration-option']", count: :any))
    |> List.first()
    |> Element.click()

    session
    |> assert_has(css("[data-testid='paper-schedule'][data-calendar-view='week']"))
    |> assert_has(css("[data-testid='paper-week'] [data-testid='week-grid']"))
  end

  # Picks the first free time on screen, checks the actions bar names it,
  # runs `after_pick` on the schedule step, and books it. Returns the day
  # and the time the clicked slot carries, `{iso_date, time}`.
  defp book(session, email, after_pick \\ fn _session -> :ok end) do
    slot =
      session
      |> find(css(@free_slot, count: :any))
      |> List.first()

    picked = {Element.attr(slot, "data-date"), Element.attr(slot, "data-time")}
    Element.click(slot)

    session =
      session
      |> assert_has(css("[data-testid='paper-selection'] .paper-selection__time"))
      |> assert_has(css("[data-testid='next-step']:not([disabled])"))

    after_pick.(session)

    session =
      session
      |> click(css("[data-testid='next-step']"))
      |> assert_has(css("[data-testid='booking-form']"))
      |> fill_in(css("input[name='booking[name]']"), with: "Paper Booker")
      |> fill_in(css("input[name='booking[email]']"), with: email)
      |> execute_script("document.activeElement.blur()")
      |> assert_has(css("[data-testid='submit-booking']:not([disabled])"))
      |> click(css("[data-testid='submit-booking']"))

    assert_has(session, css("[data-testid='paper-confirmation']"))
    picked
  end

  # The meeting starts at `date` and `time` in the booker's own timezone.
  defp assert_booked_at(email, date, time) do
    meeting = Repo.get_by!(MeetingSchema, attendee_email: email)
    local = DateTime.shift_zone!(meeting.start_time, meeting.attendee_timezone)

    assert {Date.to_iso8601(DateTime.to_date(local)), Calendar.strftime(local, "%-I:%M %p")} ==
             {date, time}
  end

  # ── Layout probes ──────────────────────────────────────────────────────

  # The page's own scroll width: the days scrolled out of a narrow week stay
  # inside its sideways scroll, screen-reader headings included, which the
  # overflow check (looking for elements past the edge outside a scroll
  # container) does not see.
  defp page_scroll_width(session) do
    script_value(session, "return document.documentElement.scrollWidth;", [])
  end

  # How many days lie wholly inside the days' visible box: the rest are
  # reached by the sideways scroll.
  defp days_in_view(session) do
    script_value(
      session,
      """
      const days = document.querySelector(".week-grid__days");
      const box = days.getBoundingClientRect();
      return [...days.querySelectorAll(".week-grid__day")].filter((day) => {
        const rect = day.getBoundingClientRect();
        return rect.left >= box.left - 1 && rect.right <= box.right + 1;
      }).length;
      """,
      []
    )
  end

  # Below seven usable columns beside them, the details are a row above
  # the week.
  defp details_above_week?(session) do
    script_value(
      session,
      """
      const details = document.querySelector(".paper-card--week .paper-details").getBoundingClientRect();
      const week = document.querySelector("[data-testid='paper-week']").getBoundingClientRect();
      return details.bottom <= week.top + 1;
      """,
      []
    )
  end

  # Times whose text does not fit their button.
  defp truncated_slots(session) do
    script_value(
      session,
      """
      return [...document.querySelectorAll("[data-testid='week-slot']")]
        .filter((slot) => slot.getClientRects().length > 0 && slot.scrollWidth > slot.clientWidth)
        .length;
      """,
      []
    )
  end

  # The height the frame last posted to the host page covers Next, so an
  # embed sized by it shows the button. The host page's listener (installed
  # by `frame/3`) adds #paper-resize-ok while that holds, which
  # `assert_has/2` waits for.
  defp assert_posted_height_covers_next(session) do
    bottom =
      script_value(
        session,
        """
        const rect = document.querySelector("[data-testid='next-step']").getBoundingClientRect();
        return Math.ceil(rect.bottom + window.scrollY);
        """,
        []
      )

    session
    |> focus_parent_frame()
    |> execute_script("window.paperResize.need = arguments[0]; window.paperResize.check();", [
      bottom
    ])
    |> assert_has(css("#paper-resize-ok"))
    |> focus_frame(css("#embed-frame"))
  end

  defp host_origin, do: Endpoint.url()

  # Frames `path` in a fresh iframe of the given width on the host page and
  # waits for its LiveView to connect (a rejected embed redirects to
  # /embed-unavailable, which has no LiveView, so this fails loudly). Before
  # the frame loads, the host page starts listening for the heights it posts.
  #
  # The frame is taller than the week, as an inline embed grows to its
  # content. In a shorter frame the browser scrolls the frame and the host
  # page only far enough to clip Next at the frame's edge, and the click is
  # lost.
  defp frame(session, path, width) do
    session
    |> execute_script(
      """
      const resize = { last: null, need: null };
      resize.check = () => {
        const ok = resize.need !== null && resize.last !== null && resize.last >= resize.need;
        const mark = document.getElementById("paper-resize-ok");
        if (ok && !mark) {
          const div = document.createElement("div");
          div.id = "paper-resize-ok";
          div.textContent = "resized";
          document.body.appendChild(div);
        } else if (!ok && mark) {
          mark.remove();
        }
      };
      window.paperResize = resize;
      window.addEventListener("message", (event) => {
        if (event.data && event.data.type === "tymeslot-resize") {
          resize.last = event.data.height;
          resize.check();
        }
      });
      document.getElementById("embed-frame")?.remove();
      const frame = document.createElement("iframe");
      frame.id = "embed-frame";
      frame.referrerPolicy = "no-referrer";
      frame.style.width = arguments[1];
      frame.style.height = "2000px";
      frame.src = arguments[0];
      document.body.appendChild(frame);
      """,
      [path, width]
    )
    |> focus_frame(css("#embed-frame"))
    |> assert_has(css("[data-phx-main].phx-connected"))
  end

  defp script_value(session, script, args) do
    me = self()
    ref = make_ref()
    execute_script(session, script, args, fn value -> send(me, {:script_value, ref, value}) end)
    assert_receive {:script_value, ^ref, value}, 5_000
    value
  end
end
