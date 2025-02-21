FROM amazonlinux:2023

RUN yum install -y python3 python3-pip zip

RUN python3 -m ensurepip --upgrade

RUN python3 -m pip install --upgrade pip --user

ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app

COPY requirements.txt .

# Install dependencies globally for execution
RUN pip3 install -r requirements.txt

# Install dependencies in lambda_package for Lambda zip
RUN pip3 install -r requirements.txt -t ./lambda_package --no-binary :none: --only-binary :all:

COPY main.py ./lambda_package/

RUN cd lambda_package && zip -r ../lambda_function.zip .

CMD ["bash"]
