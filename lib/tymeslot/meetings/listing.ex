defmodule Tymeslot.Meetings.Listing do
  @moduledoc """
  Listing, filtering, and cursor pagination for the meetings a user organises.

  Owns the read-side presentation concerns of the Meetings context: turning a
  filter string into query options and paging results with an opaque cursor. The
  query mechanics live in `MeetingListQueries`; this module orchestrates them into
  the pages the dashboard consumes.
  """

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Pagination.CursorPage

  @doc """
  Cursor-based pagination for the meetings `organizer_user_id` organises.

  Ownership is the organiser's user id, never an email address: the email
  columns on a meeting are snapshots taken at booking time, and an address can
  change hands.
  """
  @spec list_organizer_meetings_cursor_page(pos_integer(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_organizer_meetings_cursor_page(organizer_user_id, opts) do
    per_page = Keyword.get(opts, :per_page, 20)
    cursor = Keyword.get(opts, :after)

    case decode_cursor_opt(cursor) do
      :no_cursor ->
        items = list_organizer_meetings_internal(organizer_user_id, opts)
        {:ok, build_cursor_page(items, per_page)}

      {:ok, %{after_start: after_start, after_id: after_id}} ->
        items =
          opts
          |> Keyword.put(:after_start, after_start)
          |> Keyword.put(:after_id, after_id)
          |> then(&list_organizer_meetings_internal(organizer_user_id, &1))

        {:ok, build_cursor_page(items, per_page)}

      {:error, :invalid_cursor} ->
        {:error, :invalid_cursor}
    end
  end

  @doc """
  The organiser's meeting with `meeting_id` as a one-item page, loaded as the
  dashboard list loads its cards; an empty page when they own no meeting by
  that id, including when `meeting_id` is no id at all (a mangled link).
  """
  @spec list_user_meeting(integer(), term()) :: {:ok, CursorPage.t()}
  def list_user_meeting(user_id, meeting_id) when is_binary(meeting_id) do
    case UUID.cast(String.trim(meeting_id)) do
      {:ok, id} -> list_organizer_meetings_cursor_page(user_id, id: id, per_page: 1)
      :error -> {:ok, %CursorPage{items: [], page_size: 1}}
    end
  end

  def list_user_meeting(_user_id, _meeting_id), do: {:ok, %CursorPage{items: [], page_size: 1}}

  @doc """
  High-level function to list meetings for a user based on a filter string.
  """
  @spec list_user_meetings_by_filter(integer(), String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_by_filter(user_id, filter, opts) do
    per_page = Keyword.get(opts, :per_page, 20)
    after_cursor = Keyword.get(opts, :after)

    query_opts =
      case filter do
        # Held requests are deliberately kept out of "upcoming": they are not
        # upcoming meetings, they are decisions the host still owes somebody,
        # and listing them beside confirmed bookings is what made an
        # unanswered request look agreed to. A lapsed request is excluded for
        # the same reason: `expired` is a resolved outcome, not a booking
        # still to happen, even though its start time (and so `end_time`, the
        # column "past" filters on) is often still ahead of it. It falls into
        # "past" honestly once `end_time` catches up, same as any other
        # meeting that has run its course.
        "upcoming" ->
          [
            time_filter: :upcoming,
            exclude_status: ["cancelled", "awaiting_approval", "expired"],
            # Soonest first, the order a host works through them; every
            # other list stays newest first.
            order: :asc
          ]

        "past" ->
          [time_filter: :past, exclude_status: "cancelled"]

        "cancelled" ->
          [status: "cancelled"]

        "awaiting_approval" ->
          [status: "awaiting_approval"]

        _other ->
          []
      end

    query_opts = Keyword.merge(query_opts, per_page: per_page)

    query_opts =
      if after_cursor, do: Keyword.put(query_opts, :after, after_cursor), else: query_opts

    case list_organizer_meetings_cursor_page(user_id, query_opts) do
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
        error: LogFormat.reason(error),
        stacktrace: __STACKTRACE__
      )

      {:error, :failed_to_list_meetings}
  end

  defp list_organizer_meetings_internal(organizer_user_id, opts) do
    per_page = Keyword.get(opts, :per_page, 20)
    status = Keyword.get(opts, :status)
    exclude_status = Keyword.get(opts, :exclude_status)
    time_filter = Keyword.get(opts, :time_filter)
    after_start = Keyword.get(opts, :after_start)
    after_id = Keyword.get(opts, :after_id)
    order = Keyword.get(opts, :order, :desc)

    MeetingListQueries.list_meetings_for_organizer_paginated_cursor(organizer_user_id,
      id: Keyword.get(opts, :id),
      per_page: per_page,
      status: status,
      exclude_status: exclude_status,
      time_filter: time_filter,
      after_start: after_start,
      after_id: after_id,
      order: order
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
end
