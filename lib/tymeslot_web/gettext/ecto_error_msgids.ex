defmodule TymeslotWeb.Gettext.EctoErrorMsgids do
  @moduledoc """
  Registers Ecto's stock changeset validator messages with `mix
  gettext.extract` so they land in the `errors` domain catalogue.

  `Forms.translate_error/1` routes every changeset error through
  `Gettext.dgettext/dngettext` at runtime, but the message passed in is a
  variable (`msg`), not a literal — so the extractor can never see it there.
  The functions below exist purely to give the extractor literal msgids to
  find; they are never called at runtime.

  Cross-checked against `deps/ecto/lib/ecto/changeset.ex`.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  @doc false
  # Never called; exists so `mix gettext.extract` sees Ecto's stock validator
  # messages and writes them into the `errors` domain.
  @spec ecto_error_msgids() :: :ok
  def ecto_error_msgids do
    dgettext_noop("errors", "can't be blank")
    dgettext_noop("errors", "is invalid")
    dgettext_noop("errors", "has already been taken")
    dgettext_noop("errors", "is reserved")
    dgettext_noop("errors", "has invalid format")
    dgettext_noop("errors", "has an invalid entry")
    dgettext_noop("errors", "must be accepted")
    dgettext_noop("errors", "does not match confirmation")
    dgettext_noop("errors", "is still associated with this entry")
    dgettext_noop("errors", "are still associated with this entry")
    dgettext_noop("errors", "does not exist")
    dgettext_noop("errors", "violates an exclusion constraint")
    dgettext_noop("errors", "must be less than %{number}")
    dgettext_noop("errors", "must be greater than %{number}")
    dgettext_noop("errors", "must be less than or equal to %{number}")
    dgettext_noop("errors", "must be greater than or equal to %{number}")
    dgettext_noop("errors", "must be equal to %{number}")
    dgettext_noop("errors", "must be not equal to %{number}")

    dngettext_noop(
      "errors",
      "should be %{count} character(s)",
      "should be %{count} character(s)"
    )

    dngettext_noop("errors", "should be %{count} byte(s)", "should be %{count} byte(s)")
    dngettext_noop("errors", "should have %{count} item(s)", "should have %{count} item(s)")

    dngettext_noop(
      "errors",
      "should be at least %{count} character(s)",
      "should be at least %{count} character(s)"
    )

    dngettext_noop(
      "errors",
      "should be at least %{count} byte(s)",
      "should be at least %{count} byte(s)"
    )

    dngettext_noop(
      "errors",
      "should have at least %{count} item(s)",
      "should have at least %{count} item(s)"
    )

    dngettext_noop(
      "errors",
      "should be at most %{count} character(s)",
      "should be at most %{count} character(s)"
    )

    dngettext_noop(
      "errors",
      "should be at most %{count} byte(s)",
      "should be at most %{count} byte(s)"
    )

    dngettext_noop(
      "errors",
      "should have at most %{count} item(s)",
      "should have at most %{count} item(s)"
    )

    :ok
  end
end
