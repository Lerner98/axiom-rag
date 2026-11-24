/**
 * API client
 * Thin fetch wrapper around the FastAPI backend (see constants/api.ts for routes).
 */

import { API_CONFIG, API_ENDPOINTS, ERROR_CODES } from '@/constants/api';
import type { HealthResponse, IngestResponse, IngestStatusResponse } from '@/types';

// === Chat-scoped document types (ADR-007) ===

export interface ChatDocumentUploaded {
  id: string;
  name: string;
  chunk_count: number;
}

export interface ChatDocumentFailed {
  name: string;
  error: string;
}

export interface ChatDocumentUploadResponse {
  uploaded: ChatDocumentUploaded[];
  failed: ChatDocumentFailed[];
}

export interface ChatDocumentInfo {
  id: string;
  name: string;
  chunk_count: number;
  [key: string]: unknown;
}

export class ApiError extends Error {
  constructor(
    message: string,
    public code: string = ERROR_CODES.SERVER_ERROR,
    public status?: number,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

function codeForStatus(status: number): string {
  if (status === 401) return ERROR_CODES.UNAUTHORIZED;
  if (status === 403) return ERROR_CODES.FORBIDDEN;
  if (status === 404) return ERROR_CODES.NOT_FOUND;
  if (status === 422 || status === 400) return ERROR_CODES.VALIDATION_ERROR;
  return ERROR_CODES.SERVER_ERROR;
}

async function request<T>(path: string, init: RequestInit = {}, timeoutMs: number = API_CONFIG.timeout): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let res: Response;
  try {
    res = await fetch(`${API_CONFIG.baseUrl}${path}`, { ...init, signal: controller.signal });
  } catch (err) {
    if (err instanceof DOMException && err.name === 'AbortError') {
      throw new ApiError('The server took too long to respond.', ERROR_CODES.TIMEOUT);
    }
    throw new ApiError(
      'Cannot reach the Axiom backend. Is it running on ' + API_CONFIG.baseUrl + '?',
      ERROR_CODES.NETWORK_ERROR,
    );
  } finally {
    clearTimeout(timer);
  }

  if (!res.ok) {
    let message = `Request failed (${res.status})`;
    try {
      const body = await res.json();
      message = body.detail || body.error || body.message || message;
      if (typeof message !== 'string') message = JSON.stringify(message);
    } catch {
      /* non-JSON error body */
    }
    throw new ApiError(message, codeForStatus(res.status), res.status);
  }

  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

// Uploads include embedding on the server, which can take a while on CPU.
const UPLOAD_TIMEOUT_MS = 10 * 60 * 1000;

export const api = {
  health: () => request<HealthResponse>(API_ENDPOINTS.health),

  // --- Chat-scoped documents (ADR-007) ---
  uploadChatDocuments: (chatId: string, files: File[]) => {
    const form = new FormData();
    for (const file of files) form.append('files', file, file.name);
    return request<ChatDocumentUploadResponse>(
      API_ENDPOINTS.chatDocuments(chatId),
      { method: 'POST', body: form },
      UPLOAD_TIMEOUT_MS,
    );
  },

  listChatDocuments: (chatId: string) =>
    request<{ documents: ChatDocumentInfo[] }>(API_ENDPOINTS.chatDocuments(chatId)),

  deleteChatDocument: (chatId: string, docId: string) =>
    request<unknown>(API_ENDPOINTS.chatDocument(chatId, docId), { method: 'DELETE' }),

  getChatDocumentPreview: (chatId: string, docId: string) =>
    request<unknown>(API_ENDPOINTS.chatDocumentPreview(chatId, docId)),

  deleteChat: (chatId: string) =>
    request<unknown>(API_ENDPOINTS.chatDelete(chatId), { method: 'DELETE' }),

  // --- Legacy collection ingestion ---
  ingestFile: (file: File, collectionName?: string) => {
    const form = new FormData();
    form.append('file', file, file.name);
    if (collectionName) form.append('collection_name', collectionName);
    return request<IngestResponse>(API_ENDPOINTS.ingestFile, { method: 'POST', body: form }, UPLOAD_TIMEOUT_MS);
  },

  getIngestStatus: (jobId: string) => request<IngestStatusResponse>(API_ENDPOINTS.ingestStatus(jobId)),
};
