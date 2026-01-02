defmodule Tymeslot.Utils.TimeRange do
  @moduledoc """
  Pure utility functions for time range calculations and comparisons.

  This module provides common time-related operations used across the application,
  following functional programming principles with no side effects.
  """

  @doc """
  Checks if two time ranges overlap.

  Two ranges overlap if start1 < end2 AND end1 > start2.

  ## Examples

      iex> TimeRange.overlaps?(~U[2024-01-01 10:00:00Z], ~U[2024-01-01 11:00:00Z],
      ...>                      ~U[2024-01-01 10:30:00Z], ~U[2024-01-01 11:30:00Z])
      true
      
      iex> TimeRange.overlaps?(~U[2024-01-01 10:00:00Z], ~U[2024-01-01 11:00:00Z],
      ...>                      ~U[2024-01-01 11:00:00Z], ~U[2024-01-01 12:00:00Z])
      false
  """
  @spec overlaps?(
          DateTime.t() | Time.t(),
          DateTime.t() | Time.t(),
          DateTime.t() | Time.t(),
          DateTime.t() | Time.t()
        ) :: boolean()
  def overlaps?(
        %DateTime{} = start1,
        %DateTime{} = end1,
        %DateTime{} = start2,
        %DateTime{} = end2
      ) do
    DateTime.compare(start1, end2) == :lt and DateTime.compare(end1, start2) == :gt
  end

  def overlaps?(%Time{} = start1, %Time{} = end1, %Time{} = start2, %Time{} = end2) do
    Time.compare(start1, end2) == :lt and Time.compare(end1, start2) == :gt
  end

  @doc """
  Adds buffer time to a time range.

  Expands the range by subtracting buffer from start and adding to end.

  ## Examples

      iex> TimeRange.add_buffer(~U[2024-01-01 10:00:00Z], ~U[2024-01-01 11:00:00Z], 15)
      {~U[2024-01-01 09:45:00Z], ~U[2024-01-01 11:15:00Z]}
  """
  @spec add_buffer(DateTime.t(), DateTime.t(), non_neg_integer()) :: {DateTime.t(), DateTime.t()}
  def add_buffer(%DateTime{} = start_time, %DateTime{} = end_time, buffer_minutes)
      when is_integer(buffer_minutes) and buffer_minutes >= 0 do
    buffered_start = DateTime.add(start_time, -buffer_minutes, :minute)
    buffered_end = DateTime.add(end_time, buffer_minutes, :minute)
    {buffered_start, buffered_end}
  end

  @doc """
  Checks if a time range has a conflict with any event in a list.

  Takes buffer time into account when checking conflicts.

  ## Examples

      iex> events = [%{start_time: ~U[2024-01-01 09:00:00Z], end_time: ~U[2024-01-01 10:00:00Z]}]
      iex> TimeRange.has_conflict_with_events?(~U[2024-01-01 09:30:00Z], ~U[2024-01-01 10:30:00Z], events, 0)
      true
  """
  @spec has_conflict_with_events?(DateTime.t(), DateTime.t(), [map()], non_neg_integer()) ::
          boolean()
  def has_conflict_with_events?(start_time, end_time, events, buffer_minutes \\ 0) do
    Enum.any?(events, fn event ->
      {buffered_start, buffered_end} =
        add_buffer(event.start_time, event.end_time, buffer_minutes)

      overlaps?(start_time, end_time, buffered_start, buffered_end)
    end)
  end

  @doc """
  Calculates the duration between two times in minutes.

  ## Examples

      iex> TimeRange.duration_minutes(~U[2024-01-01 10:00:00Z], ~U[2024-01-01 11:30:00Z])
      90
  """
  @spec duration_minutes(DateTime.t(), DateTime.t()) :: integer()
  def duration_minutes(%DateTime{} = start_time, %DateTime{} = end_time) do
    DateTime.diff(end_time, start_time, :minute)
  end

  @doc """
  Checks if a time range is within a booking window from the current time.

  ## Examples

      iex> TimeRange.within_booking_window?(~U[2024-01-02 10:00:00Z], ~U[2024-01-01 10:00:00Z], 7)
      true
      
      iex> TimeRange.within_booking_window?(~U[2024-01-10 10:00:00Z], ~U[2024-01-01 10:00:00Z], 7)
      false
  """
  @spec within_booking_window?(DateTime.t(), DateTime.t(), pos_integer()) :: boolean()
  def within_booking_window?(%DateTime{} = slot_start, %DateTime{} = current_time, max_days)
      when is_integer(max_days) and max_days > 0 do
    max_booking_time = DateTime.add(current_time, max_days * 24 * 60 * 60, :second)

    DateTime.compare(slot_start, current_time) == :gt and
      DateTime.compare(slot_start, max_booking_time) == :lt
  end

  @doc """
  Checks if a time range meets minimum advance notice requirement.

  ## Examples

      iex> TimeRange.meets_minimum_notice?(~U[2024-01-01 12:00:00Z], ~U[2024-01-01 10:00:00Z], 60)
      true
      
      iex> TimeRange.meets_minimum_notice?(~U[2024-01-01 10:30:00Z], ~U[2024-01-01 10:00:00Z], 60)
      false
  """
  @spec meets_minimum_notice?(DateTime.t(), DateTime.t(), non_neg_integer()) :: boolean()
  def meets_minimum_notice?(%DateTime{} = slot_start, %DateTime{} = current_time, minimum_minutes)
      when is_integer(minimum_minutes) and minimum_minutes >= 0 do
    earliest_allowed = DateTime.add(current_time, minimum_minutes, :minute)
    DateTime.compare(slot_start, earliest_allowed) != :lt
  end
end
