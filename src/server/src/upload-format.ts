/// The phone normalises every capture to AAC-in-M4A before upload. Keep this
/// check at the boundary so a raw CAF can never be sent to OpenAI while merely
/// claiming to be an M4A.
export function isSupportedMemoUpload(
  contentType: string | undefined,
  audioFormat: string | undefined,
): boolean {
  const mediaType = contentType?.split(";", 1)[0]?.trim().toLowerCase();
  return mediaType === "audio/mp4" && audioFormat?.trim().toLowerCase() === "m4a";
}
