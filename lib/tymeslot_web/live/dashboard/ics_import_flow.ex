defmodule TymeslotWeb.Dashboard.IcsImportFlow do
  @moduledoc """
  The half of the calendar's `.ics` import that does not depend on which
  calendar runs it: the upload's name and options, reading the uploaded
  file, planning it, its summary, and every message the import shows or
  flashes. The calendar's `Calendar.IcsImport` keeps the stages and the modal
  and calls these; `IcsImportRunner` writes the events.

  Its strings are in `dashboard_calendar_import`, shared with the import
  modal.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.LiveView, only: [consume_uploaded_entries: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.IcsImport

  @upload :ics_file

  @type socket :: Phoenix.LiveView.Socket.t()
  @type progress ::
          (atom(), Phoenix.LiveView.UploadEntry.t(), socket() -> {:noreply, socket()})

  @doc "The name a calendar registers its `.ics` upload under."
  @spec upload_name() :: :ics_file
  def upload_name, do: @upload

  @doc """
  The options a calendar registers its `.ics` upload with: one `.ics` file
  of at most `IcsImport.max_bytes/0`, uploaded as soon as it is picked or
  dropped, each step reported to `progress`.
  """
  @spec upload_options(progress()) :: keyword()
  def upload_options(progress) when is_function(progress, 3) do
    [
      accept: ~w(.ics),
      max_entries: 1,
      max_file_size: IcsImport.max_bytes(),
      auto_upload: true,
      progress: progress
    ]
  end

  @doc """
  Reads the uploaded file. Only the file is read here: parsing a large one
  takes seconds, so the caller plans it in an async task with `plan/2`.
  `:none` when no file has finished uploading.
  """
  @spec consume(socket()) :: {:ok, String.t(), binary()} | :none
  def consume(socket) do
    consumed =
      consume_uploaded_entries(socket, @upload, fn %{path: path}, entry ->
        {:ok, {entry.client_name, File.read!(path)}}
      end)

    case consumed do
      [] -> :none
      [{file_name, content}] -> {:ok, file_name, content}
    end
  end

  @doc "Plans a file's import, reading floating times in `timezone`."
  @spec plan(binary(), String.t()) :: {:ok, IcsImport.plan()} | {:error, IcsImport.plan_error()}
  def plan(content, timezone), do: CalendarGrid.plan_ics_import(content, timezone)

  @doc "What a plan holds, as the import modal reports it."
  @spec summary(IcsImport.plan()) :: %{
          events: non_neg_integer(),
          series: non_neg_integer(),
          cancelled: non_neg_integer()
        }
  def summary(%{events: events, series: series, cancelled: cancelled}),
    do: %{events: length(events), series: series, cancelled: cancelled}

  @doc "Why the upload refused a file (an `upload_errors/2` reason)."
  @spec upload_error(atom() | nil) :: String.t()
  def upload_error(:too_large),
    do:
      dgettext(
        "dashboard_calendar_import",
        "The file is too large. Files up to %{size} MB can be imported.",
        size: div(IcsImport.max_bytes(), 1_000_000)
      )

  def upload_error(:not_accepted),
    do: dgettext("dashboard_calendar_import", "Only .ics calendar files can be imported.")

  def upload_error(_other),
    do: dgettext("dashboard_calendar_import", "The file could not be uploaded. Please try again.")

  @doc "Why a file could not be planned."
  @spec plan_error(IcsImport.plan_error()) :: String.t()
  def plan_error(:too_large), do: upload_error(:too_large)

  def plan_error(:invalid_file),
    do:
      dgettext(
        "dashboard_calendar_import",
        "This file could not be read as a calendar. Please choose an .ics file."
      )

  def plan_error(:no_events),
    do: dgettext("dashboard_calendar_import", "This file contains no events to import.")

  def plan_error(:too_many_events),
    do:
      dgettext(
        "dashboard_calendar_import",
        "This file contains more than %{count} events. Please split it into smaller files.",
        count: IcsImport.max_events()
      )

  @doc "Why an import could not start, other than one already running."
  @spec start_error(:rate_limited | :invalid_calendar) :: String.t()
  def start_error(:rate_limited),
    do:
      dgettext(
        "dashboard_calendar_import",
        "Too many imports. Please wait a while before importing another file."
      )

  def start_error(:invalid_calendar),
    do: dgettext("dashboard_calendar_import", "Invalid calendar selected")

  @doc "What a calendar says while one of the user's imports is running."
  @spec busy_message() :: String.t()
  def busy_message,
    do:
      dgettext(
        "dashboard_calendar_import",
        "An import is still running. Please wait for it to finish before importing another file."
      )

  @doc "The flash an import's result is reported with."
  @spec result_flash({:ok, IcsImport.summary()} | {:error, term()}) ::
          {:info | :warning | :error, String.t()}
  def result_flash({:ok, %{failed: 0, exclusions_dropped: 0, rules_refused: 0} = summary}),
    do: {:info, created_message(summary.created)}

  # Nothing was written, so there is no import to report, only why.
  def result_flash({:ok, %{created: 0, halted: nil} = summary}),
    do: {:error, summary |> not_imported_messages() |> Enum.join(" ")}

  def result_flash({:ok, %{created: 0, halted: reason}}), do: {:error, halted_message(reason)}

  def result_flash({:ok, summary}) do
    parts =
      [created_message(summary.created)] ++
        not_imported_messages(summary) ++
        [
          summary.halted && halted_message(summary.halted),
          summary.exclusions_dropped > 0 && exclusions_message(summary.exclusions_dropped)
        ]

    {:warning, parts |> Enum.filter(&is_binary/1) |> Enum.join(" ")}
  end

  def result_flash({:error, :already_running}), do: {:error, busy_message()}

  def result_flash({:error, :failed}),
    do:
      {:error,
       dgettext(
         "dashboard_calendar_import",
         "The import could not be finished. Some of its events may already be in your calendar."
       )}

  def result_flash({:error, _reason}), do: {:error, start_error(:invalid_calendar)}

  defp created_message(count),
    do:
      dngettext(
        "dashboard_calendar_import",
        "Imported 1 event.",
        "Imported %{count} events.",
        count
      )

  # Why events were not imported: the calendar refused or failed them, or
  # Outlook cannot store how they repeat, a series on a day some months lack
  # among them.
  defp not_imported_messages(summary) do
    Enum.filter(
      [
        summary.failed > 0 && failed_message(summary),
        summary.rules_refused > 0 && rules_refused_message(summary)
      ],
      &is_binary/1
    )
  end

  defp rules_refused_message(%{rules_refused: count, month_end_refused: month_end}) do
    message =
      dngettext(
        "dashboard_calendar_import",
        "1 event repeats in a way Outlook can't store, so it was not imported.",
        "%{count} events repeat in a way Outlook can't store, so they were not imported.",
        count
      )

    case month_end do
      0 -> message
      refused -> message <> " " <> month_end_refused_message(refused)
    end
  end

  defp failed_message(%{failed: failed, failed_titles: titles}) do
    titles = titles |> Enum.reject(&(&1 == "")) |> Enum.join(", ")

    message =
      dngettext(
        "dashboard_calendar_import",
        "1 event could not be imported.",
        "%{count} events could not be imported.",
        failed
      )

    if titles == "", do: message, else: "#{message} (#{titles})"
  end

  defp month_end_refused_message(count),
    do:
      dngettext(
        "dashboard_calendar_import",
        "1 of them repeats on a day some months don't have, which Outlook would move to the month's last day.",
        "%{count} of them repeat on a day some months don't have, which Outlook would move to the month's last day.",
        count
      )

  defp halted_message(:unauthorized),
    do:
      dgettext(
        "dashboard_calendar_import",
        "The import stopped because your calendar needs to be reconnected."
      )

  defp halted_message(reason) when reason in [:unavailable, :circuit_open],
    do:
      dgettext(
        "dashboard_calendar_import",
        "The import stopped because your calendar is not responding. Please try again later."
      )

  defp halted_message(_reason),
    do:
      dgettext(
        "dashboard_calendar_import",
        "The import stopped because the calendar could not be written to."
      )

  defp exclusions_message(count),
    do:
      dngettext(
        "dashboard_calendar_import",
        "Outlook could not take the skipped dates of 1 recurring event, so it may show extra occurrences.",
        "Outlook could not take the skipped dates of %{count} recurring events, so they may show extra occurrences.",
        count
      )
end
