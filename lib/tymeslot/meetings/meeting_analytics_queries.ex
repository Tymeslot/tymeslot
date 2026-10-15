defmodule Tymeslot.Meetings.MeetingAnalyticsQueries do
  @moduledoc """
  Aggregate queries over an organiser's meetings for the analytics
  dashboard: booking volume, attribution by `utm_source`, and converting
  visitors. Composed into user-facing figures by `Tymeslot.Analytics`
  through the `Tymeslot.Meetings` context.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

  @doc """
  Returns the count of bookings created for an organizer within the given
  window. Used by the analytics dashboard to compute conversion rate.
  """
  @spec count_bookings(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_bookings(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Returns the count of bookings grouped by `utm_source` for an organizer
  within the given window. Only returns rows where `utm_source` is set.
  Intended as a primitive for analytics composition — callers should not
  interpret the shape; use `Tymeslot.Analytics.attribution_table/3` instead.
  """
  @spec count_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), bookings: non_neg_integer()}
        ]
  def count_by_utm_source(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.utm_source))
    |> group_by([m], m.utm_source)
    |> select([m], %{utm_source: m.utm_source, bookings: count(m.id)})
    |> Repo.all()
  end

  @doc """
  Counts distinct converting visitors (meetings carrying a `visitor_hash`) for
  an organizer within the window. See `Tymeslot.Meetings.count_converting_visitors/3`.
  """
  @spec count_converting_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_converting_visitors(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.visitor_hash))
    |> select([m], count(m.visitor_hash, :distinct))
    |> Repo.one() || 0
  end

  @doc """
  Returns distinct converting-visitor counts grouped by `utm_source` for an
  organizer within the window. Only rows where both `utm_source` and
  `visitor_hash` are set.
  """
  @spec converting_visitors_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), converting_visitors: non_neg_integer()}
        ]
  def converting_visitors_by_utm_source(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.utm_source))
    |> where([m], not is_nil(m.visitor_hash))
    |> group_by([m], m.utm_source)
    |> select([m], %{
      utm_source: m.utm_source,
      converting_visitors: count(m.visitor_hash, :distinct)
    })
    |> Repo.all()
  end
end
