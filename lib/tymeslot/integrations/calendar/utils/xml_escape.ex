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

  Characters XML 1.0 forbids outright (C0 controls other than tab, newline
  and carriage return, and the non-characters U+FFFE and U+FFFF) are removed
  rather than escaped: no entity reference can carry them, and a request
  containing one is refused whole. Pasted text brings them in (`\v`, `\f`).

  Not for iCalendar. That grammar escapes `,`, `;` and newlines with
  backslashes rather than entity references, and lives in
  `Calendar.Utils.ICalBuilder`; sharing a module with it would invite calling
  the wrong one.
  """

  # Matched as bytes rather than with a Unicode regex, so a value that is not
  # valid UTF-8 is still escaped rather than raising. In valid UTF-8 the two
  # three-byte sequences only ever encode U+FFFE and U+FFFF.
  @forbidden_controls Enum.to_list(0x00..0x08) ++ [0x0B, 0x0C] ++ Enum.to_list(0x0E..0x1F)
  @forbidden Enum.map(@forbidden_controls, &<<&1>>) ++
               [<<0xEF, 0xBF, 0xBE>>, <<0xEF, 0xBF, 0xBF>>]

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
    |> String.replace(@forbidden, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
