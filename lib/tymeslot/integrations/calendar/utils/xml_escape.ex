defmodule Tymeslot.Integrations.Calendar.Utils.XmlEscape do
  @moduledoc """
  Escapes the five XML metacharacters, for the calendar protocols that build
  request bodies by hand.

  Two protocols do: CalDAV's `sync-collection` REPORT interpolates a sync
  token into an element, and the EWS builders interpolate ids, a mailbox
  address, and a seeded item's subject, body and location into attributes and
  text nodes. Both need the same five replacements in the same order, so they
  share this rather than keeping a copy each — copy-paste twins are where
  drift bugs live, and a divergence here would show up as a malformed request
  against one protocol only, which is a slow thing to diagnose.

  Not for iCalendar. That grammar escapes `,`, `;` and newlines with
  backslashes rather than entity references, and lives in
  `Calendar.Utils.ICalBuilder`; sharing a module with it would invite calling
  the wrong one.
  """

  @doc """
  Escapes `value` for interpolation into an XML attribute or text node.

  `&` is replaced first, and the order is load-bearing: escaping it last
  would double-escape the entities the other four introduce, turning `<` into
  `&amp;lt;`. No test that checks one character at a time can see that, which
  is why the round-trip test parses the result back.

  Guarded on a binary rather than calling `to_string/1`, so a `nil` reaching a
  request body raises here instead of being rendered as an empty string and
  sent as a well-formed request that means something else.
  """
  @spec escape(String.t()) :: String.t()
  def escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
