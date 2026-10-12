"""Verification only: a tiny, known-answer Core ML model. Requires coremltools."""
import sys
import coremltools as ct
from coremltools.converters.mil import Builder as mb

@mb.program(input_specs=[mb.TensorSpec(shape=(4,))], opset_version=ct.target.macOS13)
def fixture(input):
    return mb.add(x=input, y=1.0)

model = ct.convert(fixture, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS13)
model.save(sys.argv[1])
