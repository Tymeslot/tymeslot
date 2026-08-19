defmodule Tymeslot.Meetings.Listing do
  @moduledoc """
  Listing, filtering, and cursor pagination for a user's meetings.

  Owns the read-side presentation concerns of the Meetings context: turning a
  filter string into query options, paging results with an opaque cursor, and
  selecting the meetings that still need a reminder email. The query mechanics
  live in `MeetingListQueries`; this module orchestrates them into pages and lists
  the dashboard and notification workers consume.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Meetings.{MeetingListQueries, MeetingSchema}
  alias Tymeslot.Pagination.CursorPage

  @doc """
  Cursor-based pagination for a user's meetings.
  """
  @spec list_user_meetings_cursor_page(String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_cursor_page(user_email, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 20)
    cursor = Keyword.get(opts, :after)

    case decode_cursor_opt(cursor) do
      :no_cursor ->
        items = list_user_meetings_internal(user_email, opts)
        {:ok, build_cursor_page(items, per_page)}

      {:ok, %{after_start: after_start, after_id: after_id}} ->
        items =
          opts
          |> Keyword.put(:after_start, after_start)
          |> Keyword.put(:after_id, after_id)
          |> then(&list_user_meetings_internal(user_email, &1))

        {:ok, build_cursor_page(items, per_page)}

      {:error, :invalid_cursor} ->
        {:error, :invalid_cursor}
    end
  end

  @doc """
  Cursor-based pagination by user_id.
  """
  @spec list_user_meetings_cursor_page_by_id(integer(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_cursor_page_by_id(user_id, opts \\ []) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        list_user_meetings_cursor_page(user.email, opts)

      {:error, :not_found} ->
        {:ok,
         %CursorPage{
           items: [],
           next_cursor: nil,
           prev_cursor: nil,
           page_size: Keyword.get(opts, :per_page, 20),
           has_more: false
         }}
    end
  end

  @doc """
  High-level function to list meetings for a user based on a filter string.
  """
  @spec list_user_meetings_by_filter(integer(), String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_by_filter(user_id, filter, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 20)
    after_cursor = Keyword.get(opts, :after)

    query_opts =
      case filter do
        # Held requests are deliberately kept out of "upcoming": they are not
        # upcoming meetings, they are decisions the host still owes somebody,
        # and listing them beside confirmed bookings is what made an
        # unanswered request look agreed to.
        "upcoming" -> [time_filter: :upcoming, exclude_status: ["cancelled", "awaiting_approval"]]
        "past" -> [time_filter: :past, exclude_status: "cancelled"]
        "cancelled" -> [status: "cancelled"]
        "awaiting_approval" -> [status: "awaiting_approval"]
        _other -> []
      end

    query_opts = Keyword.merge(query_opts, per_page: per_page)

    query_opts =
      if after_cursor, do: Keyword.put(query_opts, :after, after_cursor), else: query_opts

    case list_user_meetings_cursor_page_by_id(user_id, query_opts) do
      {:ok, page} ->
        {:ok, page}

      {:error, :invalid_cursor} ->
        Logger.warning("Invalid pagination cursor provided", user_id: user_id)
        {:error, :invalid_cursor}
    end
  rescue
    error ->
      Logger.error("Exception while listing meetings by filter",
        user_id: user_id,
        error: inspect(error),
        stacktrace: __STACKTRACE__
      )

      {:error, :failed_to_list_meetings}
  end

  @doc """
  Returns meetings that need reminder emails sent.

  Finds confirmed meetings starting within the next hour that still have
  unsent reminders.
  """
  @spec meetings_needing_reminders() :: [MeetingSchema.t()]
  def meetings_needing_reminders do
    now = DateTime.utc_now()
    one_hour_from_now = DateTime.add(now, 1, :hour)

    Enum.filter(
      MeetingListQueries.list_meetings_needing_reminders(now, one_hour_from_now),
      &needs_reminder?/1
    )
  end

  defp list_user_meetings_internal(user_email, opts) do
    per_page = Keyword.get(opts, :per_page, 20)
    status = Keyword.get(opts, :status)
    exclude_status = Keyword.get(opts, :exclude_status)
    time_filter = Keyword.get(opts, :time_filter)
    after_start = Keyword.get(opts, :after_start)
    after_id = Keyword.get(opts, :after_id)

    MeetingListQueries.list_meetings_for_user_paginated_cursor(user_email,
      per_page: per_page,
      status: status,
      exclude_status: exclude_status,
      time_filter: time_filter,
      after_start: after_start,
      after_id: after_id
    )
  end

  defp decode_cursor_opt(nil), do: :no_cursor
  defp decode_cursor_opt(""), do: :no_cursor

  defp decode_cursor_opt(cursor) when is_binary(cursor) do
    CursorPage.decode_cursor(cursor)
  end

  defp build_cursor_page(items, per_page) do
    {items, has_more} =
      if length(items) > per_page do
        {Enum.drop(items, -1), true}
      else
        {items, false}
      end

    next_cursor =
      case List.last(items) do
        nil -> nil
        last -> CursorPage.encode_cursor(%{after_start: last.start_time, after_id: last.id})
      end

    %CursorPage{
      items: items,
      next_cursor: next_cursor,
      prev_cursor: nil,
      page_size: per_page,
      has_more: has_more
    }
  end

  defp needs_reminder?(meeting) do
    case meeting.reminders do
      nil ->
        not meeting.reminder_email_sent

      [] ->
        false

      reminders when is_list(reminders) ->
        reminders_sent = meeting.reminders_sent || []
        length(reminders) > length(reminders_sent)

      _other ->
        true
    end
  end
end
