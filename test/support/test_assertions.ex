defmodule Tymeslot.TestAssertions do
  @moduledoc """
  Common assertion helpers for functional testing.
  Focuses on behavior and data presence rather than exact text matching.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest

  @doc """
  Asserts that a meeting exists in the database with the given attributes.
  """
  @spec assert_meeting_created(keyword()) :: term()
  def assert_meeting_created(attrs) do
    import Ecto.Query
    alias Tymeslot.DatabaseSchemas.MeetingSchema
    alias Tymeslot.Repo

    query = from(m in MeetingSchema)

    query =
      if email = attrs[:attendee_email] do
        from(m in query, where: m.attendee_email == ^email)
      else
        query
      end

    query =
      if name = attrs[:attendee_name] do
        from(m in query, where: m.attendee_name == ^name)
      else
        query
      end

    meeting = Repo.one(query)
    assert meeting, "Expected meeting to be created with attributes: #{inspect(attrs)}"
    meeting
  end

  @doc """
  Asserts that an email contains required meeting information.
  """
  @spec assert_email_contains_meeting_info(term(), map()) :: term()
  def assert_email_contains_meeting_info(email, meeting_data) do
    # Check for essential data rather than exact text
    # Handle both structs and maps
    attendee_name = Map.get(meeting_data, :attendee_name)

    assert_subject_contains_meeting_info(email, attendee_name)
    assert_body_contains_attendee_name(email, attendee_name)
    assert_body_contains_duration(email, meeting_data)
    assert_body_contains_date(email, meeting_data)
  end

  defp assert_subject_contains_meeting_info(email, attendee_name) do
    if attendee_name do
      assert email.subject =~ attendee_name or
               String.downcase(email.subject) =~ "appointment" or
               String.downcase(email.subject) =~ "meeting",
             "Expected subject to contain attendee name or appointment/meeting"
    end
  end

  defp assert_body_contains_attendee_name(email, attendee_name) do
    if attendee_name do
      assert email.html_body =~ attendee_name
    end
  end

  defp assert_body_contains_duration(email, meeting_data) do
    duration = Map.get(meeting_data, :duration_minutes) || Map.get(meeting_data, :duration)

    if duration do
      assert email.html_body =~ to_string(duration)
    end
  end

  defp assert_body_contains_date(email, meeting_data) do
    scheduled_at =
      Map.get(meeting_data, :scheduled_at) ||
        Map.get(meeting_data, :start_time) ||
        Map.get(meeting_data, :date)

    if scheduled_at do
      date_parts = extract_date_parts(scheduled_at)
      assert_date_in_body(email, date_parts)
    end
  end

  defp extract_date_parts(scheduled_at) do
    case scheduled_at do
      %DateTime{} = dt ->
        d = DateTime.to_date(dt)
        {d.year, d.month, d.day}

      %Date{} = d ->
        {d.year, d.month, d.day}

      _ ->
        nil
    end
  end

  defp assert_date_in_body(_email, nil), do: :ok

  defp assert_date_in_body(email, {year, month, day}) do
    month_name = get_month_name(month)

    # Check for various date formats
    assert email.html_body =~ to_string(year) or
             email.html_body =~ month_name or
             email.html_body =~ String.slice(month_name, 0..2) or
             email.html_body =~ to_string(day),
           "Expected email to contain date information (year: #{year}, month: #{month_name}, day: #{day})"
  end

  defp get_month_name(month) do
    months = %{
      1 => "January",
      2 => "February",
      3 => "March",
      4 => "April",
      5 => "May",
      6 => "June",
      7 => "July",
      8 => "August",
      9 => "September",
      10 => "October",
      11 => "November",
      12 => "December"
    }

    Map.get(months, month, "")
  end

  @doc """
  Asserts that a LiveView contains a form with specific fields.
  """
  @spec assert_form_has_fields(term(), String.t(), list()) :: term()
  def assert_form_has_fields(view, form_selector, fields) do
    form_html = view |> element(form_selector) |> render()

    Enum.each(fields, fn field ->
      assert form_html =~ ~s(name="#{field}") or
               form_html =~ ~s(name="booking[#{field}]") or
               form_html =~ ~s(name="meeting[#{field}]"),
             "Expected form to have field: #{field}"
    end)
  end

  @doc """
  Asserts that a view displays an error for a specific field.
  """
  @spec assert_field_error(term(), String.t()) :: term()
  def assert_field_error(view, field) do
    html = render(view)
    # Look for common error patterns without checking exact text
    assert html =~ ~s(phx-feedback-for="booking[#{field}]") or
             html =~ ~s(phx-feedback-for="meeting[#{field}]") or
             html =~ ~r/class="[^"]*invalid[^"]*"[^>]*name="[^"]*#{field}/ or
             html =~ ~r/class="[^"]*error[^"]*"[^>]*#{field}/,
           "Expected error feedback for field: #{field}"
  end

  @doc """
  Asserts that time slots are displayed without checking exact times.
  """
  @spec assert_time_slots_displayed(String.t(), keyword()) :: term()
  def assert_time_slots_displayed(html, opts \\ []) do
    min_slots = Keyword.get(opts, :min_slots, 1)

    # Look for time slot patterns (e.g., buttons with time-like text)
    time_pattern = ~r/\d{1,2}:\d{2}\s*(AM|PM)/i
    matches = Regex.scan(time_pattern, html)

    assert length(matches) >= min_slots,
           "Expected at least #{min_slots} time slots, found #{length(matches)}"
  end

  @doc """
  Asserts calendar navigation works without checking specific text.
  """
  @spec assert_calendar_navigation(term()) :: term()
  def assert_calendar_navigation(view) do
    # Check that navigation elements exist
    assert has_element?(view, "[data-testid='calendar-prev']") or
             has_element?(view, "button[phx-click='prev_month']") or
             has_element?(view, "button", "←"),
           "Expected previous month navigation"

    assert has_element?(view, "[data-testid='calendar-next']") or
             has_element?(view, "button[phx-click='next_month']") or
             has_element?(view, "button", "→"),
           "Expected next month navigation"
  end

  @doc """
  Asserts that a meeting can be rescheduled/cancelled.
  """
  @spec assert_meeting_actions_available(String.t(), term()) :: term()
  def assert_meeting_actions_available(html, meeting) do
    # Check for action links/buttons without relying on exact text
    assert html =~ ~r/href="[^"]*\/meeting\/#{meeting.uid}\/reschedule/ or
             html =~ ~r/phx-click="reschedule".*data-uid="#{meeting.uid}"/ or
             html =~ meeting.uid,
           "Expected reschedule action for meeting"
  end

  @doc """
  Fills out a booking form with data.
  """
  @spec fill_booking_form(term(), map()) :: term()
  def fill_booking_form(view, data) do
    view
    |> form("form", booking: data)
    |> render_change()
  end

  @doc """
  Submits a booking form and returns the result.
  """
  @spec submit_booking_form(term(), map()) :: term()
  def submit_booking_form(view, data) do
    view
    |> form("form", booking: data)
    |> render_submit()
  end

  @doc """
  Asserts successful form submission by checking for redirect or success message.
  """
  @spec assert_form_submitted_successfully(term()) :: true | term()
  def assert_form_submitted_successfully(view) do
    # Check for common success indicators
    case view do
      {:error, {:redirect, %{to: _path}}} ->
        # It was redirected, which indicates success
        true

      _ ->
        html = render(view)

        assert html =~ "success" or html =~ "confirmed" or html =~ "thank",
               "Expected success indication in view"
    end
  end

  @doc """
  Gets the current step from a multi-step form.
  """
  @spec get_current_step(term()) :: integer() | nil
  def get_current_step(view) do
    html = render(view)

    cond do
      html =~ "step-1-active" or html =~ ~r/data-step="1".*active/ -> 1
      html =~ "step-2-active" or html =~ ~r/data-step="2".*active/ -> 2
      html =~ "step-3-active" or html =~ ~r/data-step="3".*active/ -> 3
      true -> nil
    end
  end
end
