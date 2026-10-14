/**
 * A request or response violated the OpenBox wire contract (missing fields, unknown verdict,
 * malformed JSON). Treated exactly like an unavailable service: no write.
 */
public class OpenBoxContractException extends OpenBoxException {
}
