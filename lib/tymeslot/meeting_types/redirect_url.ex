defmodule Tymeslot.MeetingTypes.RedirectUrl do
  @moduledoc """
  The address a meeting type sends its bookers to once a new booking is made
  (`redirect_url`), kept apart from `Tymeslot.MeetingTypes.MeetingTypeSchema`
  like its other rules (`Tymeslot.MeetingTypes.EmailVerificationRule`).

  Blank means "stay on Tymeslot's own confirmation" and is stored as NULL, so
  a host clearing the field turns the redirect off rather than storing an
  empty address the booking page would have to tell apart from none.

  Anything else must be an absolute `http` or `https` address with a host:
  the booking page hands it to the browser as a top-level navigation
  (`Phoenix.LiveView.redirect/2` with `external:`), and to the embedding
  page's script, so a relative path, a `javascript:` or `data:` URL, or a
  host-less `https:///path` must never get that far. 2048 characters is the
  longest address every browser still navigates to reliably, and leaves
  room for the booking details `Tymeslot.Bookings.RedirectParams` appends.

  `check/1` is the one rule, so the form's instant feedback and the
  changeset cannot disagree. Its errors are `{msgid, opts}` pairs of the
  `errors` domain, the shape `Ecto.Changeset.add_error/4` stores and
  `TymeslotWeb.Components.CoreComponents.Forms.translate_error/1` reads.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset, only: [add_error: 4, get_change: 2, update_change: 3]

  @max_length 2048
  @schemes ~w(http https)

  @typedoc "An error as a changeset stores it: an `errors`-domain msgid and its bindings."
  @type error :: {String.t(), keyword()}

  @doc "The longest address accepted, in characters."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  The address to store for `value`: `{:ok, nil}` for a blank one (nothing to
  redirect to), `{:ok, url}` trimmed for a valid one, `{:error, error}`
  otherwise.
  """
  @spec check(term()) :: {:ok, String.t() | nil} | {:error, error()}
  def check(nil), do: {:ok, nil}

  def check(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      url -> check_url(url)
    end
  end

  def check(_value), do: {:error, invalid()}

  @doc """
  Normalises and validates a changed `redirect_url`: blank becomes NULL, an
  address is trimmed, and an invalid one is refused with the `check/1`
  error. Only a change is checked, so a changeset that does not touch the
  field (toggling `is_active`, say) never fails on it.
  """
  @spec validate_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_changeset(changeset) do
    changeset = update_change(changeset, :redirect_url, &trim_to_nil/1)

    case get_change(changeset, :redirect_url) do
      nil ->
        changeset

      url ->
        case check_url(url) do
          {:ok, _url} -> changeset
          {:error, {message, opts}} -> add_error(changeset, :redirect_url, message, opts)
        end
    end
  end

  defp check_url(url) do
    cond do
      String.length(url) > @max_length ->
        {:error,
         {"should be at most %{count} character(s)",
          count: @max_length, validation: :length, kind: :max, type: :string}}

      absolute_web_address?(url) ->
        {:ok, url}

      true ->
        {:error, invalid()}
    end
  end

  # `URI.new/1` refuses whitespace and other characters a browser would have
  # to guess about, and lowercases the scheme, so "HTTPS://" passes as well.
  defp absolute_web_address?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in @schemes and is_binary(host) ->
        host != ""

      _other ->
        false
    end
  end

  defp invalid,
    do:
      {dgettext_noop("errors", "must be a full web address starting with http:// or https://"),
       validation: :format}

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_to_nil(value), do: value
end
