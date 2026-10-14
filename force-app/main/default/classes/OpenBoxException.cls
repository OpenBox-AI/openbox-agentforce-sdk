/**
 * Base type for every failure raised by the OpenBox integration.
 * Callers that only need to know "governance did not produce a usable decision" catch this type;
 * a write must never proceed after one is raised.
 */
public virtual class OpenBoxException extends Exception {
}
