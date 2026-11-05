import type { ChangeEvent } from "react"

/**
 * Note and file control for photographic evidence.
 * The note wraps inside its own box. A single-line input let long notes paint
 * over the native file control ("Choose File" sitting inside the note text).
 */
export function PhotoAttachFields({
  note,
  onNoteChange,
  noteAriaLabel = "Photo note",
  fileAriaLabel,
  accept,
  disabled,
  maxLength = 500,
  onFile,
}: {
  note: string
  onNoteChange: (value: string) => void
  noteAriaLabel?: string
  fileAriaLabel: string
  accept: string
  disabled?: boolean
  maxLength?: number
  onFile: (file: File | undefined) => void
}) {
  function choose(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]
    // Allow the same file to be chosen again after a failed finalize.
    event.target.value = ""
    onFile(file)
  }

  return (
    <div className="grid min-w-0 gap-3">
      <label className="grid min-w-0 gap-1 text-sm">
        Note
        <textarea
          aria-label={noteAriaLabel}
          value={note}
          disabled={disabled}
          rows={2}
          maxLength={maxLength}
          onChange={(event) => onNoteChange(event.target.value)}
          className="min-h-16 w-full min-w-0 resize-y overflow-auto rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm break-words"
        />
      </label>
      <input
        aria-label={fileAriaLabel}
        type="file"
        accept={accept}
        disabled={disabled}
        onChange={choose}
        className="block w-full max-w-full min-w-0 text-sm file:mr-3 file:rounded-md file:border file:border-input file:bg-background file:px-3 file:py-1.5"
      />
    </div>
  )
}
