defmodule Tymeslot.Test.KnownMsgid do
  @moduledoc """
  Whether a string stored for later display is a msgid the integration card
  can translate.

  `ConnectionLabels` translates a stored `sync_error` by looking the English
  up as a msgid in its reason domains. A string that is not one of them, such
  as a sentence with a value interpolated or an exception's own text, is
  shown untranslated, so a writer of `sync_error` must store a msgid exactly.
  The English locale cannot tell the two apart (it answers every lookup with
  the lookup itself), so this reads the extracted templates instead.
  """

  alias Expo.Message.Singular
  alias Expo.PO
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionLabels

  @spec known?(String.t()) :: boolean()
  def known?(string) when is_binary(string), do: MapSet.member?(msgids(), string)

  defp msgids do
    for domain <- ConnectionLabels.reason_domains(),
        %Singular{msgid: msgid} <- PO.parse_file!(template(domain)).messages,
        into: MapSet.new(),
        do: IO.iodata_to_binary(msgid)
  end

  defp template(domain), do: Application.app_dir(:tymeslot, "priv/gettext/#{domain}.pot")
end
