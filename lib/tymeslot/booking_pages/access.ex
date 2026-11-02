defmodule Tymeslot.BookingPages.Access do
  @moduledoc """
  Whether an account may create and change its booking pages: the
  `:booking_pages_allowed` feature (`Tymeslot.Features.check_access/2`). The
  profile's own page at `/<username>` is never gated, only the extra pages.

  Without the feature, existing pages stay published and bookable, and may
  still be deleted, but nothing about them changes: not their details, theme,
  texts, colours and uploads, nor which meeting types they list. Every one of
  those writes asks here first, so a stale dashboard cannot get round it.

  Core's default checker allows every feature, so a self-hoster is never
  refused; a deployment that sells the feature configures a checker that
  answers for it.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Features
  alias Tymeslot.Profiles.ProfileQueries

  @feature :booking_pages_allowed

  @doc "Whether `user_id` may create and change booking pages."
  @spec allowed?(integer()) :: boolean()
  def allowed?(user_id) when is_integer(user_id), do: check(user_id) == :ok

  @doc """
  `:ok` when `user_id` may create and change booking pages. Any refusal,
  including a checker that failed, is `{:error, :upgrade_required}`: a write
  that cannot be shown to be allowed is not made.
  """
  @spec check(integer()) :: :ok | {:error, :upgrade_required}
  def check(user_id) when is_integer(user_id) do
    case Features.check_access(user_id, @feature) do
      :ok -> :ok
      {:error, _denied} -> {:error, :upgrade_required}
    end
  end

  @doc "What a refused write tells the host."
  @spec locked_message() :: String.t()
  def locked_message,
    do:
      dgettext(
        "dashboard_booking_pages",
        "This booking page is read-only on your current plan. Upgrade to change it."
      )

  @doc "As `check/1`, for the owner of the profile `profile_id`."
  @spec check_profile(integer()) :: :ok | {:error, :upgrade_required}
  def check_profile(profile_id) when is_integer(profile_id) do
    case ProfileQueries.user_id_for_profile(profile_id) do
      nil -> {:error, :upgrade_required}
      user_id -> check(user_id)
    end
  end
end
