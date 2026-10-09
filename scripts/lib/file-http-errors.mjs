export class FileHttpError extends Error {
  constructor(status, code, cause) {
    super(code, { cause });
    this.status = status;
    this.code = code;
  }
}

export function classifyFileError(error) {
  if (error instanceof FileHttpError) return error;
  const message = error instanceof Error ? error.message : String(error || 'UNKNOWN');
  // InvalidAuthHeader / OIDC errors come from Convex when the bearer token is malformed or expired.
  if (message === 'UNAUTHORIZED' || /Unauthenticated|Authentication|InvalidAuthHeader|Could not (parse JWT|verify OIDC token)/i.test(message)) {
    return new FileHttpError(401, 'UNAUTHORIZED', error);
  }
  if (/FORBIDDEN|ACCESS_DENIED/i.test(message)) {
    return new FileHttpError(403, 'FILE_ACCESS_DENIED', error);
  }
  if (/NOT_FOUND/i.test(message)) return new FileHttpError(404, 'FILE_NOT_FOUND', error);
  if (/UPLOAD_(NOT_FINALIZED|CLEANUP_IN_PROGRESS|CLEANUP_CLAIM_LOST|ALREADY_COMMITTED|CLAIM_INVALID)/i.test(message)) {
    return new FileHttpError(409, 'UPLOAD_CONFLICT', error);
  }
  if (/TOO_LARGE/i.test(message)) return new FileHttpError(413, 'FILE_TOO_LARGE', error);
  if (/INVALID_DATE_RANGE/i.test(message)) {
    return new FileHttpError(400, 'INVALID_DATE_RANGE', error);
  }
  if (/INVALID_FILE|SIZE_MISMATCH|INVALID_UPLOAD|ArgumentValidation|Invalid argument/i.test(message)) {
    return new FileHttpError(400, 'INVALID_FILE', error);
  }
  if (/DRIVE_DOWNLOAD_QUEUE_FULL|context deadline exceeded|client\.timeout|request canceled|timed? out|econnreset|temporarily unavailable/i.test(message)) {
    return new FileHttpError(503, 'FILE_TEMPORARILY_UNAVAILABLE', error);
  }
  return new FileHttpError(500, 'FILE_SERVER_ERROR', error);
}
