defmodule Tymeslot.Emails.RecipientLocale do
  @moduledoc """
  Resolves the locale an email renders in, and runs the render inside it.

  Emails are rendered outside any request. The Oban worker hands each send to a
  fresh `Task.Supervisor` process whose Gettext locale is unset, so `dgettext/2`
  resolves against `default_locale/0` no matter who the recipient is. An email
  that does not establish a locale is therefore not "locale-agnostic" — it is
  silently English. Every user-facing email must wrap its rendering (subject
  included) in one of the functions here.

  The locale belongs to the **recipient**, never to whoever triggered the send.
  An admin changing a user's address, or a webhook cancelling a booking, must
  still produce mail in the reader's language.

  Booking mail resolves its locale from the meeting (`attendee_locale`) and is
  wrapped by `Tymeslot.Emails.AppointmentBuilder`; this module covers the
  account, auth, and calendar mail addressed to a registered user, whose locale
  lives on `users.locale`.

  `users.locale` is nullable, and NULL means "no explicit choice" — the web layer
  reads such a user's locale from their browser, which an email has no access to.
  A NULL therefore resolves to the default locale rather than raising.
  """

  alias Tymeslot.Auth
  alias Tymeslot.Locales

  @doc """
  Runs `fun` with the Gettext locale set to `user`'s, restoring it afterwards.

  Accepts any map carrying an optional `:locale`, so it works with both `User`
  structs and the looser `t:Tymeslot.Emails.EmailService.user_map/0`.
  """
  @spec with_user_locale(map(), (-> result)) :: result when result: var
  def with_user_locale(user, fun) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale_for(user), fun)
  end

  @doc """
  Runs `fun` with the Gettext locale of the user identified by `user_id`.

  For senders that hold only an id — calendar mail keys off `organizer_user_id`.
  An unknown or `nil` id falls back to the default locale: a sync-failure alert
  must still go out even if the owner row has since been deleted.
  """
  @spec with_user_id_locale(term(), (-> result)) :: result when result: var
  def with_user_id_locale(user_id, fun) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale_for_user_id(user_id), fun)
  end

  @doc "The locale to render for `user`, defaulting when unset or unsupported."
  @spec locale_for(map()) :: String.t()
  def locale_for(%{locale: locale}) do
    if Locales.acceptable?(locale), do: locale, else: Locales.default_locale()
  end

  def locale_for(_user), do: Locales.default_locale()

  @doc "The locale to render for the user identified by `user_id`."
  @spec locale_for_user_id(term()) :: String.t()
  def locale_for_user_id(nil), do: Locales.default_locale()

  def locale_for_user_id(user_id) do
    case Auth.get_user(user_id) do
      {:ok, user} -> locale_for(user)
      {:error, :not_found} -> Locales.default_locale()
    end
  end
end
