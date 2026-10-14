export function emailInitial(email: string | undefined) {
  const letter = email?.trim().charAt(0)
  return letter ? letter.toUpperCase() : "S"
}
