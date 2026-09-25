defmodule Tymeslot.Emails.Shared.Stack do
  @moduledoc """
  Keeps the blocks of an email body apart.

  Every tinted block — an alert, the attendee's note, the video call, a
  details card — is an `mj-section` carrying its own background. A section's
  `padding` sits *inside* that background, so two of them in a row touch: the
  tint of one begins where the tint of the other ends, with nothing between.
  Three in a row, as a confirmation with a note and a video link has, read as
  one striped slab.

  MJML has no margin. The gap therefore comes from wrapping a block in an
  `mj-wrapper` whose padding lies outside the block's own background — the
  same device `Frame` already uses to inset the card from the canvas.

  The wrapper carries the surface colour rather than staying transparent: a
  client that fills unpainted regions with its own default would otherwise
  show a stripe of it in the gap.
  """

  alias Tymeslot.Emails.Shared.Styles

  # Enough to read as a separation at a glance without loosening the body into
  # unrelated fragments; a little tighter than the 20px the card keeps from
  # its own edges, so blocks still read as belonging to one email.
  @gap "14px"

  @doc """
  Wraps `block` so that whatever follows it starts a gap lower.

  Applied by the block itself rather than by the templates that place it, so a
  new email cannot forget it and no template has to know which of the things
  it stacks happen to be tinted.
  """
  @spec spaced(iodata(), keyword()) :: String.t()
  def spaced(block, opts \\ []) do
    gap = Keyword.get(opts, :gap, @gap)

    """
    <mj-wrapper padding="0 0 #{gap} 0" background-color="#{Styles.surface()}">
    #{block}
    </mj-wrapper>
    """
  end

  @doc "The standard gap between stacked blocks."
  @spec gap() :: String.t()
  def gap, do: @gap
end
