defmodule Tymeslot.Meetings.BookerContact do
  @moduledoc """
  The contact rules a booker's details must pass before they can become a
  `meeting_participants` row. `ParticipantSchema` applies them when a seat is
  taken and `SeatHoldSchema` when one is held, so a hold that saves can always
  convert and the two cannot drift apart.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.Locales

  @required ~w(name email timezone locale)a

  @doc """
  Normalises the email, requires `name`, `email`, `timezone` and `locale`,
  validates the email's format and checks the locale is a supported one.
  """
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> validate_required(@required)
    |> EmailChangeset.validate_email(:email)
    |> validate_inclusion(:locale, Locales.supported_codes(),
      message: dgettext_noop("errors", "is not a supported locale")
    )
  end

  @doc "An email address as a participant row stores it: trimmed and lower-cased."
  @spec normalize_email(String.t() | nil) :: String.t() | nil
  def normalize_email(nil), do: nil

  def normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end
end
