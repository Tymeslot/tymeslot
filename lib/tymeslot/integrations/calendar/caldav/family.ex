defmodule Tymeslot.Integrations.Calendar.CalDAV.Family do
  @moduledoc """
  The CalDAV family: one row per provider that speaks CalDAV, holding what
  tells the members apart.

  Every registry that lists the family derives from this table rather than
  restating it: the `:caldav` family in `ProviderConfig`, its display names
  and locked server URLs, and the client provider `CaldavCommon` stamps on a
  client built from a stored row. Adding a member is one row here, and a
  member missing from a registry cannot happen.

  The table depends on nothing but the Gettext backend (for marking its
  tooltips), so the modules deriving from it at compile time take on no
  other compile-time dependency through it.

  Columns:

    * `:display_name`: the brand, untranslated, as it reads the same in every
      locale.
    * `:client_provider`: the provider a client built from a stored row
      carries, which keys its circuit breaker. `nil` for generic CalDAV, whose
      client takes the server type detected from its URL instead.
    * `:fixed_url`: the one server address the provider has, with the
      tooltip explaining why the field cannot be edited (an untranslated
      msgid), or `nil` when the owner enters their own. A fixed address is
      enforced where a submitted configuration is validated, not only by the
      locked form field.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @type member :: :caldav | :radicale | :nextcloud | :zimbra | :mailbox_org | :apple | :baikal

  @type row :: %{
          display_name: String.t(),
          client_provider: member() | nil,
          fixed_url: %{url: String.t(), tooltip: String.t()} | nil
        }

  # A keyword list rather than a map: the order is the order the family is
  # listed in everywhere it is derived.
  @members [
    caldav: %{display_name: "CalDAV", client_provider: nil, fixed_url: nil},
    radicale: %{display_name: "Radicale", client_provider: :radicale, fixed_url: nil},
    nextcloud: %{display_name: "Nextcloud", client_provider: :nextcloud, fixed_url: nil},
    zimbra: %{display_name: "Zimbra", client_provider: :zimbra, fixed_url: nil},
    mailbox_org: %{
      display_name: "mailbox.org",
      client_provider: :mailbox_org,
      fixed_url: %{
        url: "https://dav.mailbox.org",
        tooltip:
          dgettext_noop(
            "integrations_calendar",
            "mailbox.org always uses this CalDAV server, so the address cannot be changed"
          )
      }
    },
    apple: %{
      display_name: "Apple iCloud",
      client_provider: :apple,
      fixed_url: %{
        url: "https://caldav.icloud.com",
        tooltip:
          dgettext_noop(
            "integrations_calendar",
            "Apple iCloud always uses this CalDAV server, so the address cannot be changed"
          )
      }
    },
    baikal: %{display_name: "Baikal", client_provider: :baikal, fixed_url: nil}
  ]

  @doc "The family's members, in listing order."
  @spec members() :: [member()]
  def members, do: Keyword.keys(@members)

  @doc "A member's row. Raises for a provider outside the family."
  @spec row!(member()) :: row()
  def row!(member), do: Keyword.fetch!(@members, member)

  @doc "A member's brand name."
  @spec display_name(member()) :: String.t()
  def display_name(member), do: row!(member).display_name

  @doc """
  The members a client built from a stored row names explicitly, keyed by the
  provider's string form as the row stores it. Generic CalDAV is absent: its
  client provider is detected from the URL.
  """
  @spec client_providers() :: %{String.t() => member()}
  def client_providers do
    for {member, %{client_provider: provider}} <- @members, provider != nil, into: %{} do
      {Atom.to_string(member), provider}
    end
  end

  @doc "The members whose server address is fixed, with that address."
  @spec fixed_urls() :: %{member() => %{url: String.t(), tooltip: String.t()}}
  def fixed_urls do
    for {member, %{fixed_url: fixed}} <- @members, fixed != nil, into: %{}, do: {member, fixed}
  end
end
