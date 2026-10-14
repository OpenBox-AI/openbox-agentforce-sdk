/**
 * OpenBox Core could not be reached, timed out, or answered with a non-success HTTP status.
 * Never an approval: governed writes fail closed on this exception.
 */
public class OpenBoxTransportException extends OpenBoxException {
    public Integer statusCode { get; private set; }

    public OpenBoxTransportException withStatusCode(Integer statusCode) {
        this.statusCode = statusCode;
        return this;
    }
}
