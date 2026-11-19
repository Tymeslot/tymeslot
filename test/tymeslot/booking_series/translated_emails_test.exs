defmodule Tymeslot.BookingSeries.TranslatedEmailsTest do
  @moduledoc """
  A series booked in one of the organiser's translation languages: every
  series email to the booker names the meeting type in their copy, and
  every one to the organiser (the confirmation, the request and its
  reminder, the cancellation) in the organiser's own wording, as a single
  booking's emails do.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :emails
  @moduletag :i18n
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Notifications
  alias Tymeslot.CalendarMock
  alias Tymeslot.Workers.EmailWorker

  @translations %{
    "de" => %{"name" => %{"text" => "Coaching-Termin", "source" => :erlang.phash2("Mentoring")}}
  }

  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    # The real email service, so the rendered emails reach this process.
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    host =
      create_always_bookable_profile(
        timezone: "Etc/UTC",
        profile: %{
          username: "grace-host",
          full_name: "Grace Hopper",
          content_locale: "en",
          translation_locales: ["de"]
        }
      )

    %{host: host}
  end

  defp series_type(host, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: host.user,
          name: "Mentoring",
          duration_minutes: 30,
          translations: @translations,
          series_mode: :recurring,
          series_frequency: :weekly,
          series_interval: 1,
          series_min_occurrences: 2,
          series_max_occurrences: 12
        ],
        attrs
      )
    )
  end

  defp book_in_german(host, type, count) do
    first_start = Date.utc_today() |> Date.add(7) |> DateTime.new!(~T[10:00:00], "Etc/UTC")

    assert {:ok, booked} =
             BookingSeries.book(
               %{
                 duration: 30,
                 user_timezone: "Etc/UTC",
                 organizer_user_id: host.user.id,
                 meeting_type_id: type.id,
                 attendee_locale: "de",
                 series: %{mode: :recurring, first_start: first_start, count: count}
               },
               %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => ""}
             )

    booked
  end

  defp drain_emails(opts \\ []),
    do: Oban.drain_queue([queue: :emails, with_recursion: true] ++ opts)

  defp sent_emails(acc \\ []) do
    receive do
      {:email, email} -> sent_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp to_ada?(email), do: email.to == [{"Ada Lovelace", "ada@example.com"}]

  defp assert_wording(emails) do
    {[_one | _rest] = to_attendee, [_another | _more] = to_organizer} =
      Enum.split_with(emails, &to_ada?/1)

    for email <- to_attendee do
      assert email.html_body =~ "Coaching-Termin"
      refute email.html_body =~ "Mentoring"
    end

    for email <- to_organizer do
      assert email.html_body =~ "Mentoring"
      assert email.text_body =~ "Mentoring"
      refute email.html_body =~ "Coaching-Termin"
      refute email.text_body =~ "Coaching-Termin"
    end
  end

  test "the series confirmation is in each reader's wording", %{host: host} do
    %{meetings: [first | _rest]} = book_in_german(host, series_type(host), 3)

    assert first.attendee_texts["de"]["meeting_type"] == "Coaching-Termin"
    assert first.meeting_type == "Mentoring"

    drain_emails()
    assert_wording(sent_emails())
  end

  test "the series cancellation is in each reader's wording", %{host: host} do
    %{series: series, meetings: [_first | rest]} = book_in_german(host, series_type(host), 3)
    drain_emails()
    _confirmation = sent_emails()

    cancelled =
      for meeting <- rest, do: meeting |> Changeset.change(status: :cancelled) |> Repo.update!()

    assert {:ok, :scheduled} =
             Notifications.schedule_series_cancellation(series, cancelled, :attendee)

    assert [job] =
             all_enqueued(worker: EmailWorker, args: %{"action" => "send_series_cancellation"})

    assert :ok = perform_job(EmailWorker, job.args)
    assert_wording(sent_emails())
  end

  test "the series request and its reminder are in each reader's wording", %{host: host} do
    type = series_type(host, requires_approval: true, approval_window_hours: 48)
    book_in_german(host, type, 3)

    drain_emails(with_scheduled: true)
    emails = sent_emails()

    assert [_reminder] = Enum.filter(emails, &(&1.subject =~ "Reminder: Ada"))
    assert_wording(emails)
  end
end
