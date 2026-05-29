package com.example.orderservice.model;

public record OrderRequest(String product, int quantity, int pricePerUnit) {}
