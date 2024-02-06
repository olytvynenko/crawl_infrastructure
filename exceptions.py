class ValidationError(Exception):
    def __init__(self, message=None, errors=None):
        if message is None:
            message = "Validation error"

        # Call the base class constructor with the parameters it needs
        super().__init__(message)

        # Now for your custom code...
        self.errors = errors


class ParameterValidationError(Exception):
    def __init__(self, message=None, errors=None):
        # Call the base class constructor with the parameters it needs
        super().__init__(f"Input parameters not valid: {message}")

        # Now for your custom code...
        self.errors = errors
